package ai.quranlab.tajweedformer.flutter

import ai.quranlab.tajweedformer.SharingSettingsView
import ai.quranlab.tajweedformer.SharingTheme
import ai.quranlab.tajweedformer.TajweedClient
import android.app.Activity
import android.app.Dialog
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.GradientDrawable
import android.util.TypedValue
import android.view.ViewGroup
import android.view.Window
import android.widget.FrameLayout
import android.widget.ScrollView
import kotlin.math.min

/**
 * The SDK's own sharing settings (`SharingSettingsView`: the switch, what is shared, delete, the recovery code) in a
 * card over the Flutter activity, for `client.sharing.openSettings()`. The view is the SDK's public one; the card
 * around it is the plugin's, in the sheet design's background (white, or 0xFF1C1C1E in the dark) unless the app's
 * `SharingTheme` gives one.
 */
internal object SettingsCard {
    private const val LIGHT = 0xFFFFFFFF.toInt()
    private const val DARK = 0xFF1C1C1E.toInt()

    /** The card's background: the theme's, else the design's for the theme's or the activity's light or dark. */
    fun background(theme: SharingTheme, night: Boolean): Int = theme.background ?: if (theme.dark ?: night) DARK else LIGHT

    fun show(a: Activity, client: TajweedClient): Boolean {
        if (a.isFinishing || a.isDestroyed) return false
        val theme = SharingTheme.current
        val night = (a.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES
        val d = Dialog(a)
        d.requestWindowFeature(Window.FEATURE_NO_TITLE)
        val dp = { v: Float -> TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v, a.resources.displayMetrics) }
        val card = FrameLayout(a)
        card.background = GradientDrawable().apply { setColor(background(theme, night)); cornerRadius = dp(theme.cornerRadiusDp) }
        val pad = dp(20f).toInt()
        card.setPadding(pad, pad, pad, pad)
        val scroll = ScrollView(a)
        scroll.isVerticalScrollBarEnabled = false
        scroll.addView(SharingSettingsView(a, client, theme))
        card.addView(scroll)
        d.setContentView(card)
        d.setCancelable(true)
        d.setCanceledOnTouchOutside(true)
        d.window?.setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
        val dm = a.resources.displayMetrics
        d.window?.setLayout(min((dm.widthPixels * 0.92).toInt(), dp(480f).toInt()), ViewGroup.LayoutParams.WRAP_CONTENT)
        d.show()
        return true
    }
}
