package chat.trix.android.core.system

import android.content.Context
import java.io.IOException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

class BackendConfigStore(
    context: Context,
) {
    private val appContext = context.applicationContext
    private val preferences = appContext.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)

    fun readBaseUrl(): String? {
        return preferences.getString(KEY_BASE_URL, null)
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?.trimEnd('/')
    }

    suspend fun writeBaseUrl(baseUrl: String) = withContext(Dispatchers.IO) {
        val saved = preferences.edit()
            .putString(KEY_BASE_URL, baseUrl.trimEnd('/'))
            .commit()
        if (!saved) {
            throw IOException("Failed to save backend URL")
        }
    }

    companion object {
        private const val PREFERENCES_NAME = "trix_backend_config"
        private const val KEY_BASE_URL = "base_url"
    }
}
