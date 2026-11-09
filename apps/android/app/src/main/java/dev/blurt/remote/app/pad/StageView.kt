// Where the computer's screen is drawn: one GL surface the size of the pad. The decoder renders into a SurfaceTexture; each time a frame is
// latched here, its timestamp says which frame it is and so which part of the screen it shows, and it's drawn there in the same pass. That is
// the iPhone's "plain layer, crop and pixels change in one commit" (Pad/ScreenStream.swift): a new crop only changes the sharpness, never
// where the picture sits. A view the system composes on its own clock (a plain SurfaceView, or a TextureView fed by the decoder) can't
// promise that: for a frame the old crop would show in the new place, and the picture would twitch.
//
// Under the video, the last sight of the whole screen (the backdrop): a move past what's been sent shows that until the sharp part comes.
// Corners are rounded by 6 dp in the shader; a rounded corner on a picture is a piece of the screen not seen, so no more than that.
package dev.blurt.remote.app.pad

import android.content.Context
import android.graphics.SurfaceTexture
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.opengl.GLSurfaceView
import android.view.Surface
import dev.blurt.remote.app.dp
import dev.blurt.remote.core.RemoteCrop
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import java.util.concurrent.atomic.AtomicInteger
import javax.microedition.khronos.egl.EGLConfig
import javax.microedition.khronos.opengles.GL10

class StageView(c: Context) : GLSurfaceView(c) {
    /** What to draw, set from the main thread; read on the GL thread. All in screen units 0…1. */
    class Scene {
        @Volatile var view = doubleArrayOf(0.0, 0.0, 1.0, 1.0)      // port.rect: x, y, w, h
        @Volatile var showBackdrop = false
        @Volatile var on = false
    }

    val scene = Scene()
    /** the decoder's output, once the GL side has made it */
    @Volatile var surface: Surface? = null
        private set
    var onSurface: ((Surface?) -> Unit)? = null
    /** the frame on screen now shows this part: called on the GL thread */
    var onShown: ((RemoteCrop) -> Unit)? = null
    /** frame timestamps (µs) to the part of the screen each shows; the decoder fills it */
    val crops = java.util.Collections.synchronizedMap(object : LinkedHashMap<Long, RemoteCrop>() {
        override fun removeEldestEntry(e: MutableMap.MutableEntry<Long, RemoteCrop>?) = size > 64
    })
    @Volatile var wantBackdrop = false
    @Volatile private var clearFrame = false

    private val renderer = R()

    init {
        setEGLContextClientVersion(2)
        setEGLConfigChooser(8, 8, 8, 8, 0, 0)
        preserveEGLContextOnPause = true
        setRenderer(renderer)
        renderMode = RENDERMODE_WHEN_DIRTY
    }

    /** Nothing showing any more: the next draw is black. */
    fun clear() {
        clearFrame = true
        requestRender()
    }

    private inner class R : Renderer, SurfaceTexture.OnFrameAvailableListener {
        private var oes = 0
        private var st: SurfaceTexture? = null
        private val pending = AtomicInteger(0)
        private var program = 0
        private var backProgram = 0
        private var w = 1
        private var h = 1
        private val texMatrix = FloatArray(16)
        private var shown: RemoteCrop? = null
        private var hasFrame = false
        // the backdrop: a copy of the last whole frame
        private var fbo = 0
        private var backTex = 0
        private var backW = 0
        private var backH = 0
        private var hasBack = false
        private var lastBackCopy = 0L
        private val quad: FloatBuffer = ByteBuffer.allocateDirect(8 * 4).order(ByteOrder.nativeOrder()).asFloatBuffer().apply {
            put(floatArrayOf(0f, 0f, 1f, 0f, 0f, 1f, 1f, 1f)); position(0)
        }

        override fun onSurfaceCreated(gl: GL10?, config: EGLConfig?) {
            val t = IntArray(1)
            GLES20.glGenTextures(1, t, 0)
            oes = t[0]
            GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oes)
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
            st?.release()
            val s = SurfaceTexture(oes)
            s.setOnFrameAvailableListener(this)
            st = s
            program = link(VERTEX, FRAGMENT_OES)
            backProgram = link(VERTEX, FRAGMENT_2D)
            hasFrame = false
            hasBack = false
            fbo = 0
            val out = Surface(s)
            surface = out
            post { onSurface?.invoke(out) }
        }

        override fun onSurfaceChanged(gl: GL10?, width: Int, height: Int) {
            w = maxOf(1, width)
            h = maxOf(1, height)
            GLES20.glViewport(0, 0, w, h)
        }

        override fun onFrameAvailable(t: SurfaceTexture?) {
            pending.incrementAndGet()
            requestRender()
        }

        override fun onDrawFrame(gl: GL10?) {
            val s = st ?: return
            if (clearFrame) {
                clearFrame = false
                hasFrame = false
                hasBack = false
                shown = null
            }
            var n = pending.getAndSet(0)
            while (n-- > 0) {
                runCatching { s.updateTexImage() }
                hasFrame = true
            }
            if (hasFrame) {
                s.getTransformMatrix(texMatrix)
                val crop = crops[s.timestamp / 1000] ?: shown ?: RemoteCrop.WHOLE
                if (crop != shown) {
                    shown = crop
                    onShown?.invoke(crop)
                }
            }
            val crop = shown ?: RemoteCrop.WHOLE
            // keep the last whole frame for the backdrop: a few times a second, or at once when a move is about to need it
            val now = System.nanoTime()
            if (hasFrame && crop == RemoteCrop.WHOLE && (wantBackdrop || now - lastBackCopy > 250_000_000L)) {
                copyToBackdrop()
                lastBackCopy = now
                wantBackdrop = false
            }

            GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)
            GLES20.glViewport(0, 0, w, h)
            GLES20.glClearColor(0f, 0f, 0f, 1f)
            GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
            if (!scene.on || !hasFrame) return
            val v = scene.view
            if (scene.showBackdrop && hasBack) draw(backProgram, GLES20.GL_TEXTURE_2D, backTex, IDENTITY, 0.0, 0.0, 1.0, 1.0, v, flipY = false)
            draw(program, GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oes, texMatrix, crop.x.toDouble(), crop.y.toDouble(), crop.w.toDouble(), crop.h.toDouble(), v, flipY = false)
        }

        /** A part of the screen (fx, fy, fw, fh) drawn where it belongs for the view (v), as a fraction of the stage. */
        private fun draw(p: Int, target: Int, tex: Int, m: FloatArray, fx: Double, fy: Double, fw: Double, fh: Double, v: DoubleArray, flipY: Boolean) {
            GLES20.glUseProgram(p)
            val x0 = (fx - v[0]) / v[2]
            val y0 = (fy - v[1]) / v[3]
            val x1 = (fx + fw - v[0]) / v[2]
            val y1 = (fy + fh - v[1]) / v[3]
            GLES20.glUniform4f(GLES20.glGetUniformLocation(p, "uRect"), x0.toFloat(), y0.toFloat(), x1.toFloat(), y1.toFloat())
            GLES20.glUniformMatrix4fv(GLES20.glGetUniformLocation(p, "uTex"), 1, false, m, 0)
            GLES20.glUniform1f(GLES20.glGetUniformLocation(p, "uFlip"), if (flipY) 1f else 0f)
            GLES20.glUniform2f(GLES20.glGetUniformLocation(p, "uSize"), w.toFloat(), h.toFloat())
            GLES20.glUniform1f(GLES20.glGetUniformLocation(p, "uRadius"), CORNER)
            GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
            GLES20.glBindTexture(target, tex)
            GLES20.glUniform1i(GLES20.glGetUniformLocation(p, "uSampler"), 0)
            val a = GLES20.glGetAttribLocation(p, "aPos")
            GLES20.glEnableVertexAttribArray(a)
            GLES20.glVertexAttribPointer(a, 2, GLES20.GL_FLOAT, false, 0, quad)
            GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
            GLES20.glDisableVertexAttribArray(a)
        }

        private fun copyToBackdrop() {
            // half the stage's size is plenty: it's only seen for the moment before the sharp part arrives
            val bw = maxOf(64, w / 2)
            val bh = maxOf(64, h / 2)
            if (fbo == 0 || bw != backW || bh != backH) {
                val ids = IntArray(1)
                if (fbo != 0) { GLES20.glDeleteFramebuffers(1, intArrayOf(fbo), 0); GLES20.glDeleteTextures(1, intArrayOf(backTex), 0) }
                GLES20.glGenTextures(1, ids, 0)
                backTex = ids[0]
                GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, backTex)
                GLES20.glTexImage2D(GLES20.GL_TEXTURE_2D, 0, GLES20.GL_RGBA, bw, bh, 0, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, null)
                GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
                GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
                GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
                GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
                GLES20.glGenFramebuffers(1, ids, 0)
                fbo = ids[0]
                GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, fbo)
                GLES20.glFramebufferTexture2D(GLES20.GL_FRAMEBUFFER, GLES20.GL_COLOR_ATTACHMENT0, GLES20.GL_TEXTURE_2D, backTex, 0)
                backW = bw
                backH = bh
            }
            GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, fbo)
            GLES20.glViewport(0, 0, backW, backH)
            val ow = w
            val oh = h
            w = backW
            h = backH
            draw(program, GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oes, texMatrix, 0.0, 0.0, 1.0, 1.0, doubleArrayOf(0.0, 0.0, 1.0, 1.0), flipY = false)
            w = ow
            h = oh
            hasBack = true
        }

        private fun link(vs: String, fs: String): Int {
            fun shader(type: Int, src: String): Int {
                val s = GLES20.glCreateShader(type)
                GLES20.glShaderSource(s, src)
                GLES20.glCompileShader(s)
                return s
            }
            val p = GLES20.glCreateProgram()
            GLES20.glAttachShader(p, shader(GLES20.GL_VERTEX_SHADER, vs))
            GLES20.glAttachShader(p, shader(GLES20.GL_FRAGMENT_SHADER, fs))
            GLES20.glLinkProgram(p)
            return p
        }
    }

    private companion object {
        val CORNER = 6.dp
        val IDENTITY = FloatArray(16).also { android.opengl.Matrix.setIdentityM(it, 0) }

        // aPos is 0…1 of the quad; uRect where it goes on the stage, 0…1 from the top left
        const val VERTEX = """
            attribute vec2 aPos;
            uniform vec4 uRect;
            uniform mat4 uTex;
            uniform float uFlip;
            varying vec2 vTex;
            varying vec2 vStage;
            void main() {
                vec2 s = mix(uRect.xy, uRect.zw, aPos);
                vStage = s;
                gl_Position = vec4(s.x * 2.0 - 1.0, 1.0 - s.y * 2.0, 0.0, 1.0);
                vec2 t = vec2(aPos.x, mix(1.0 - aPos.y, aPos.y, uFlip));
                vTex = (uTex * vec4(t, 0.0, 1.0)).xy;
            }
        """

        /** inside the stage's rounded rectangle, or nothing */
        const val CLIP = """
            uniform vec2 uSize;
            uniform float uRadius;
            float inside(vec2 st) {
                vec2 p = st * uSize;
                vec2 q = abs(p - uSize * 0.5) - (uSize * 0.5 - vec2(uRadius));
                float d = length(max(q, 0.0)) - uRadius;
                return clamp(0.5 - d, 0.0, 1.0);
            }
        """

        const val FRAGMENT_OES = """
            #extension GL_OES_EGL_image_external : require
            precision mediump float;
            varying vec2 vTex;
            varying vec2 vStage;
            uniform samplerExternalOES uSampler;
        """ + CLIP + """
            void main() { gl_FragColor = vec4(texture2D(uSampler, vTex).rgb * inside(vStage), 1.0); }
        """

        const val FRAGMENT_2D = """
            precision mediump float;
            varying vec2 vTex;
            varying vec2 vStage;
            uniform sampler2D uSampler;
        """ + CLIP + """
            void main() { gl_FragColor = vec4(texture2D(uSampler, vTex).rgb * inside(vStage), 1.0); }
        """
    }
}
