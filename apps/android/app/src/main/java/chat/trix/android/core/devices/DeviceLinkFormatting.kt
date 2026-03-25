package chat.trix.android.core.devices

import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement

fun shortDeviceIdentifier(value: String): String {
    return if (value.length <= 10) {
        value
    } else {
        "${value.take(6)}…${value.takeLast(4)}"
    }
}

@OptIn(ExperimentalSerializationApi::class)
fun prettyPrintJsonOrRaw(value: String): String {
    return runCatching {
        Json {
            prettyPrint = true
            prettyPrintIndent = "  "
        }.encodeToString(
            JsonElement.serializer(),
            Json.parseToJsonElement(value),
        )
    }.getOrDefault(value)
}

fun formatLinkExpiry(
    epochSeconds: Long,
    zoneId: ZoneId = ZoneId.systemDefault(),
): String {
    return DateTimeFormatter.ofPattern("MMM d, HH:mm")
        .withZone(zoneId)
        .format(Instant.ofEpochSecond(epochSeconds))
}
