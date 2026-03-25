package chat.trix.android.core.system

import android.graphics.Bitmap
import android.graphics.Color
import com.google.zxing.BarcodeFormat
import com.google.zxing.qrcode.QRCodeWriter

fun renderQrCodeBitmap(
    content: String,
    sizePx: Int = 768,
): Bitmap {
    require(content.isNotBlank()) { "QR payload cannot be empty" }
    require(sizePx > 0) { "QR size must be positive" }

    val matrix = QRCodeWriter().encode(content, BarcodeFormat.QR_CODE, sizePx, sizePx)
    val pixels = IntArray(sizePx * sizePx)
    for (y in 0 until sizePx) {
        val rowOffset = y * sizePx
        for (x in 0 until sizePx) {
            pixels[rowOffset + x] = if (matrix.get(x, y)) {
                Color.BLACK
            } else {
                Color.WHITE
            }
        }
    }

    return Bitmap.createBitmap(sizePx, sizePx, Bitmap.Config.ARGB_8888).apply {
        setPixels(pixels, 0, sizePx, 0, 0, sizePx, sizePx)
    }
}
