package dev.blurt.remote.app

import android.content.Intent
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.Until
import org.junit.Assert.assertNotNull
import org.junit.Test
import org.junit.runner.RunWith

/** Two fingers on the pad, which adb's input can't do: a pinch out zooms the picture like a photo. Needs a paired computer that can show its
 *  screen (the fake host will do). It leaves the view zoomed, for a screenshot. */
@RunWith(AndroidJUnit4::class)
class PinchTest {
    @Test fun pinchZoomsThePicture() {
        val i = InstrumentationRegistry.getInstrumentation()
        val device = UiDevice.getInstance(i)
        i.targetContext.startActivity(Intent(i.targetContext, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        val show = device.wait(Until.findObject(By.desc(i.targetContext.getString(R.string.show_screen))), 8000)
        assertNotNull("the screen button", show)
        // connected first: the button works only then
        Thread.sleep(2500)
        show.click()
        Thread.sleep(3500)
        val pad = device.wait(Until.findObject(By.desc(i.targetContext.getString(R.string.trackpad))), 5000)
        assertNotNull("the pad", pad)
        pad.setGestureMargin(pad.visibleBounds.width() / 5)
        pad.pinchOpen(0.9f, 700)
        Thread.sleep(2500)
        // the view as it is now, zoomed: adb exec-out run-as dev.blurt.remote cat files/pinched.png > pinched.png
        device.takeScreenshot(java.io.File(i.targetContext.filesDir, "pinched.png"))
    }
}
