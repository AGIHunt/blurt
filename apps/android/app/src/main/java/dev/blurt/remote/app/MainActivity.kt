// The one activity. Everything stays in it (the sheets are Compose over the main screen), and it handles turning, folding and resizing
// itself, so none of those restarts it: the session, the keys held, the zoomed view all carry on, and the stream is asked for its new size.
//
// Full screen and immersive: edge swipes show the system bars first rather than leaving the app, and the keys at the screen's sides get
// their strips back from the system's back gesture (PadLayout.exclusions). The screen stays on while the app is open, and dims after five
// minutes untouched (PadScreen).
package dev.blurt.remote.app

import android.Manifest
import android.content.Intent
import android.content.pm.ActivityInfo
import android.content.pm.PackageManager
import android.graphics.Rect
import android.os.Build
import android.os.Bundle
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.WindowManager
import android.widget.FrameLayout
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.ui.platform.ComposeView
import androidx.core.content.ContextCompat
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import androidx.window.layout.FoldingFeature
import androidx.window.layout.WindowInfoTracker
import dev.blurt.remote.app.pad.PadLayout
import dev.blurt.remote.app.pad.PadScreen
import dev.blurt.remote.app.sheets.Sheet
import dev.blurt.remote.app.sheets.SheetHost
import dev.blurt.remote.app.sheets.Sheets
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity(), PadScreen.Sheets {
    private lateinit var screen: PadScreen
    private lateinit var sheetView: ComposeView
    private val sheets = Sheets()
    private var touching = 0

    private val askMic = registerForActivityResult(ActivityResultContracts.RequestPermission()) { ok ->
        // the computer now knows which microphone to use
        Remote.link.send(dev.blurt.remote.core.ToMac.SetMicOnPhone(Remote.mic.usable))
        if (!ok && !shouldShowRequestPermissionRationale(Manifest.permission.RECORD_AUDIO)) sheets.show(Sheet.MicDenied)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Remote.start(applicationContext)
        WindowCompat.setDecorFitsSystemWindows(window, false)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        if (Build.VERSION.SDK_INT >= 30) window.attributes.layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
        else if (Build.VERSION.SDK_INT >= 28) window.attributes.layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        immersive()

        val root = FrameLayout(this)
        screen = PadScreen(this, this)
        root.addView(screen, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
        sheetView = ComposeView(this).apply { setContent { SheetHost(sheets, screen) } }
        root.addView(sheetView, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
        setContentView(root)
        Haptics.view = root

        ViewCompat.setOnApplyWindowInsetsListener(root) { _, insets ->
            val cut = insets.getInsets(WindowInsetsCompat.Type.displayCutout())
            val bars = insets.getInsetsIgnoringVisibility(WindowInsetsCompat.Type.systemGestures())
            screen.safe = Rect(cut.left, cut.top, cut.right, maxOf(cut.bottom, if (insets.isVisible(WindowInsetsCompat.Type.navigationBars())) bars.bottom else 0))
            val ime = insets.getInsets(WindowInsetsCompat.Type.ime()).bottom
            screen.imeHeight = if (screen.field.open && ime > 120 * resources.displayMetrics.density) ime else 0
            insets
        }
        screen.bind(lifecycleScope)
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                WindowInfoTracker.getOrCreate(this@MainActivity).windowLayoutInfo(this@MainActivity).collect { info ->
                    val d = resources.displayMetrics.density
                    val f = info.displayFeatures.filterIsInstance<FoldingFeature>().firstOrNull()
                    screen.reshaped()
                    screen.fold = f?.takeIf { it.isSeparating || it.state == FoldingFeature.State.HALF_OPENED }?.let {
                        // where it is in this window, not on the display
                        val b = it.bounds
                        val loc = IntArray(2).also { a -> screen.getLocationOnScreen(a) }
                        PadLayout.Fold(dev.blurt.remote.app.pad.Frame((b.left - loc[0]) / d, (b.top - loc[1]) / d, (b.right - loc[0]) / d, (b.bottom - loc[1]) / d),
                            it.orientation == FoldingFeature.Orientation.VERTICAL, it.state == FoldingFeature.State.HALF_OPENED)
                    }
                }
            }
        }
        // the sheets' layer is there only while it has something to show: a sheet, or the question a link from outside asks
        lifecycleScope.launch {
            kotlinx.coroutines.flow.combine(sheets.current, Remote.link.offered) { s, o -> s != null || o != null }.collect { on ->
                sheetView.visibility = if (on) android.view.View.VISIBLE else android.view.View.GONE
            }
        }
        dev.blurt.remote.app.pad.TestWeather.from(intent)
        handle(intent)
    }

    private fun immersive() {
        val c = WindowInsetsControllerCompat(window, window.decorView)
        c.hide(WindowInsetsCompat.Type.systemBars())
        c.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        dev.blurt.remote.app.pad.TestWeather.from(intent)
        handle(intent)
    }

    /** A pairing link from outside (the camera app, a web page): it asks first. */
    private fun handle(i: Intent?) {
        val u = i?.data ?: return
        if (u.scheme == "blurtremote") Remote.link.openExternal(u.toString())
        i.data = null
    }

    override fun onResume() {
        super.onResume()
        immersive()
        Remote.link.foreground()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) immersive() else Remote.link.leaving()     // the shade over the app: let go of what's held, keep the connection
    }

    override fun onPause() {
        super.onPause()
        screen.letGo()
    }

    override fun onStop() {
        super.onStop()
        Remote.link.background()
    }

    override fun onConfigurationChanged(newConfig: android.content.res.Configuration) {
        super.onConfigurationChanged(newConfig)
        screen.reshaped()
        // a new shape: the stream is asked for what fits it
        Remote.screen.planChanged()
    }

    // MARK: leaning back mustn't turn the screen under a thumb

    override fun dispatchTouchEvent(e: MotionEvent): Boolean {
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> { touching = 1; requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_LOCKED }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> { touching = 0; requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_FULL_USER }
        }
        return super.dispatchTouchEvent(e)
    }

    // MARK: a keyboard on a tablet goes to the computer

    // Activity's own dispatchKeyEvent; lint takes it for androidx.core's restricted override of the same name
    @android.annotation.SuppressLint("RestrictedApi")
    override fun dispatchKeyEvent(e: KeyEvent): Boolean {
        if (sheets.current.value == null && HardwareKeys.handle(e)) return true
        return super.dispatchKeyEvent(e)
    }

    // MARK: PadScreen.Sheets

    override fun settings() = sheets.show(Sheet.Settings)
    override fun pairing() = sheets.show(Sheet.Pair)
    override fun editor() = sheets.show(Sheet.Editor)
    override fun switchMac() = sheets.show(Sheet.Switch)
    override fun displays() = sheets.show(Sheet.Displays)
    override fun askMic() {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) return
        askMic.launch(Manifest.permission.RECORD_AUDIO)
    }
    override fun keepAwake(on: Boolean) {
        if (on) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON) else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }
}
