package chat.trix.android

import android.content.Intent
import android.os.Bundle
import android.os.StrictMode
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import chat.trix.android.ui.TrixApp

class MainActivity : ComponentActivity() {
    private var launchIntentState by mutableStateOf<Intent?>(null)
    private var launchBaseUrlOverrideState by mutableStateOf<String?>(null)
    private var interopActionJsonState by mutableStateOf<String?>(null)
    private var interopResultFileNameState by mutableStateOf<String?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (BuildConfig.DEBUG) {
            StrictMode.setThreadPolicy(
                StrictMode.ThreadPolicy.Builder()
                    .detectAll()
                    .penaltyLog()
                    .build(),
            )
            StrictMode.setVmPolicy(
                StrictMode.VmPolicy.Builder()
                    .detectAll()
                    .penaltyLog()
                    .build(),
            )
        }
        enableEdgeToEdge()
        launchIntentState = intent
        updateLaunchState(intent)
        setContent {
            TrixApp(
                launchIntent = launchIntentState,
                launchBaseUrlOverride = launchBaseUrlOverrideState,
                interopActionJson = interopActionJsonState,
                interopResultFileName = interopResultFileNameState,
            )
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        launchIntentState = intent
        updateLaunchState(intent)
    }

    private fun updateLaunchState(intent: Intent?) {
        val actionJson = intent?.getStringExtra(ANDROID_INTEROP_ACTION_JSON_EXTRA)
            ?.trim()
            ?.takeIf(String::isNotEmpty)
        val resultFileName = intent?.getStringExtra(ANDROID_INTEROP_RESULT_PATH_EXTRA)
            ?.trim()
            ?.takeIf(String::isNotEmpty)

        interopActionJsonState = actionJson
        interopResultFileNameState = resultFileName
        launchBaseUrlOverrideState = if (actionJson != null && resultFileName != null) {
            BuildConfig.TRIX_INTEROP_BASE_URL.trim().takeIf(String::isNotEmpty)
        } else {
            null
        }
    }
}

private const val ANDROID_INTEROP_ACTION_JSON_EXTRA = "TRIX_INTEROP_ACTION_JSON"
private const val ANDROID_INTEROP_RESULT_PATH_EXTRA = "TRIX_INTEROP_RESULT_PATH"
