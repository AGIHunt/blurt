// Pairing (port of Sheets/PairSheet.swift): the camera reads the code the computer shows, with ZXing on CameraX's frames, all on the phone,
// nothing downloaded. The camera is asked for only here, when it's needed. The pairing link the computer copies can be pasted too, always:
// for a computer that isn't beside the phone (the link came by chat or email), a phone without a camera, or a code that won't read.
package dev.blurt.remote.app.sheets

import android.Manifest
import android.content.ClipboardManager
import android.content.pm.PackageManager
import android.util.Size
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import com.google.zxing.BarcodeFormat
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.MultiFormatReader
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.common.HybridBinarizer
import dev.blurt.remote.app.Haptics
import dev.blurt.remote.app.R
import dev.blurt.remote.app.Remote
import dev.blurt.remote.core.RemotePairing
import java.util.concurrent.Executors

@Composable
fun PairSheet(onClose: () -> Unit) {
    val ctx = LocalContext.current
    // the link used last: after a pairing that didn't take, it's still here to try again or change
    var link by remember { mutableStateOf(Remote.link.lastLink) }
    var failed by remember { mutableStateOf<Int?>(null) }
    val hasCamera = remember { ctx.packageManager.hasSystemFeature(PackageManager.FEATURE_CAMERA_ANY) }
    var allowed by remember { mutableStateOf(ContextCompat.checkSelfPermission(ctx, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) }
    var refused by remember { mutableStateOf(false) }
    val ask = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { ok -> allowed = ok; refused = !ok }
    LaunchedEffect(Unit) { if (hasCamera && !allowed) ask.launch(Manifest.permission.CAMERA) }

    /** A code the camera read, or text with the link in it (alone, or inside a message from a chat app). */
    fun use(s: String, scanned: Boolean = false) {
        val p = RemotePairing.find(s)
        if (p == null || !Remote.link.open(p.url)) { failed = if (scanned) R.string.not_blurt_code else R.string.not_pairing_link; return }
        if (!scanned) Remote.link.lastLink = p.url
        Haptics.grab()
        onClose()
    }

    Column(Modifier.fillMaxSize()) {
        SheetTop(stringResource(R.string.pair_title), navigation = { TextButton(onClose) { Text(stringResource(R.string.cancel)) } })
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(20.dp), horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(16.dp)) {
            if (hasCamera) {
                Box(Modifier.widthIn(max = 420.dp).fillMaxWidth().aspectRatio(1f).clip(RoundedCornerShape(20.dp)).background(Color.Black), contentAlignment = Alignment.Center) {
                    if (allowed) Scanner { code -> use(code, scanned = true) }
                    else if (refused) Text(stringResource(R.string.camera_off), Modifier.padding(24.dp), color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center)
                }
            }
            Text(stringResource(R.string.status_unpaired), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center)
            // the link the computer copies (Copy Link), for a code that's far away or won't read: Paste reads the clipboard only when
            // tapped and uses it at once; the field takes it typed, or pasted inside a message
            OutlinedTextField(link, { link = it; failed = null }, Modifier.widthIn(max = 420.dp).fillMaxWidth(), singleLine = true,
                label = { Text(stringResource(R.string.pairing_link)) },
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, imeAction = ImeAction.Go),
                keyboardActions = KeyboardActions(onGo = { if (link.isNotBlank()) use(link) }),
                trailingIcon = {
                    TextButton({
                        val clip = ctx.getSystemService(ClipboardManager::class.java)?.primaryClip?.takeIf { it.itemCount > 0 }
                        val s = clip?.getItemAt(0)?.coerceToText(ctx)?.toString().orEmpty()
                        if (s.isNotBlank()) { link = s; use(s) } else failed = R.string.not_pairing_link
                    }, Modifier.padding(end = 4.dp)) { Text(stringResource(R.string.paste)) }
                })
            if (!(hasCamera && allowed) || link.isNotBlank()) {
                Button({ use(link) }, enabled = link.isNotBlank()) { Text(stringResource(R.string.connect)) }
            }
            failed?.let { Text(stringResource(it), color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
        }
    }
}

/** The camera's picture, read for QR codes a few times a second. */
@Composable
private fun Scanner(onCode: (String) -> Unit) {
    val ctx = LocalContext.current
    val owner = LocalLifecycleOwner.current
    val exec = remember { Executors.newSingleThreadExecutor() }
    val reader = remember {
        MultiFormatReader().apply { setHints(mapOf(DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.QR_CODE), DecodeHintType.TRY_HARDER to true)) }
    }
    var last by remember { mutableStateOf<String?>(null) }
    val view = remember { PreviewView(ctx).apply { scaleType = PreviewView.ScaleType.FILL_CENTER } }
    DisposableEffect(Unit) {
        val future = ProcessCameraProvider.getInstance(ctx)
        future.addListener({
            val provider = future.get()
            val preview = Preview.Builder().build().also { it.surfaceProvider = view.surfaceProvider }
            val analysis = ImageAnalysis.Builder()
                .setResolutionSelector(ResolutionSelector.Builder().setResolutionStrategy(ResolutionStrategy(Size(1280, 720), ResolutionStrategy.FALLBACK_RULE_CLOSEST_LOWER_THEN_HIGHER)).build())
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .build()
            analysis.setAnalyzer(exec) { img -> read(img, reader)?.let { s -> view.post { if (s != last) { last = s; onCode(s) } } } }
            runCatching {
                provider.unbindAll()
                provider.bindToLifecycle(owner, CameraSelector.DEFAULT_BACK_CAMERA, preview, analysis)
            }.onFailure {
                runCatching { provider.bindToLifecycle(owner, CameraSelector.DEFAULT_FRONT_CAMERA, preview, analysis) }
            }
        }, ContextCompat.getMainExecutor(ctx))
        onDispose {
            runCatching { future.get().unbindAll() }
            exec.shutdown()
        }
    }
    AndroidView({ view }, Modifier.fillMaxSize())
}

private fun read(img: ImageProxy, reader: MultiFormatReader): String? = try {
    val y = img.planes[0]
    val buf = y.buffer
    val data = ByteArray(buf.remaining()).also { buf.get(it) }
    val src = PlanarYUVLuminanceSource(data, y.rowStride, img.height, 0, 0, img.width, img.height, false)
    reader.decodeWithState(BinaryBitmap(HybridBinarizer(src))).text?.takeIf { it.startsWith("blurtremote:") }
} catch (_: Exception) {
    null
} finally {
    reader.reset()
    img.close()
}
