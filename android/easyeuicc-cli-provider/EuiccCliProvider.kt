package im.angry.openeuicc.cli

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.Bundle
import android.os.ParcelFileDescriptor
import im.angry.openeuicc.OpenEuiccApplication
import im.angry.openeuicc.core.EuiccChannel
import im.angry.openeuicc.util.displayName
import im.angry.openeuicc.util.switchProfile
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject

class EuiccCliProvider : ContentProvider() {
    private data class CliProfile(
        val slotId: Int,
        val portId: Int,
        val seId: Int,
        val logicalSlotId: Int,
        val eid: String,
        val iccid: String,
        val state: String,
        val name: String,
        val nickName: String,
        val displayName: String,
        val provider: String,
        val profileClass: String
    )

    private val app: OpenEuiccApplication
        get() = context!!.applicationContext as OpenEuiccApplication

    override fun onCreate() = true

    override fun getType(uri: Uri): String =
        when (uri.lastPathSegment) {
            "profiles.json" -> "application/json"
            "profiles.txt" -> "text/plain"
            else -> "application/json"
        }

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?
    ): Cursor {
        val columns = arrayOf(
            "slotId", "portId", "seId", "logicalSlotId", "eid", "iccid", "state",
            "name", "nickName", "displayName", "provider", "class"
        )
        return MatrixCursor(columns).apply {
            profiles().forEach { p ->
                addRow(arrayOf(
                    p.slotId, p.portId, p.seId, p.logicalSlotId, p.eid, p.iccid, p.state,
                    p.name, p.nickName, p.displayName, p.provider, p.profileClass
                ))
            }
        }
    }

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        return openPipeHelper(uri, getType(uri), null, null as String?) { output, targetUri, _, _, _ ->
            val data = when (targetUri.lastPathSegment) {
                "profiles.txt" -> profilesText()
                "profiles.json" -> profilesJson().toString(2) + "\n"
                else -> switchFromUri(targetUri).toString(2) + "\n"
            }
            ParcelFileDescriptor.AutoCloseOutputStream(output).use {
                it.write(data.toByteArray(Charsets.UTF_8))
            }
        }
    }

    override fun call(method: String, arg: String?, extras: Bundle?): Bundle {
        val result = when (method) {
            "list" -> JSONObject().put("ok", true).put("profiles", profilesJson())
            "switch" -> switchProfileByTarget(arg.orEmpty())
            "switch-iccid" -> switchProfileByIccid(arg.orEmpty())
            else -> errorJson("unknown method: $method")
        }
        return Bundle().apply { putString("json", result.toString()) }
    }

    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?) = 0
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?) = 0

    private fun switchFromUri(uri: Uri): JSONObject =
        when (uri.pathSegments.firstOrNull()) {
            "switch-iccid" -> switchProfileByIccid(uri.pathSegments.getOrNull(1).orEmpty())
            "switch" -> switchProfileByTarget(uri.getQueryParameter("target").orEmpty())
            "switch-exact" -> switchProfileExact(
                uri.getQueryParameter("name").orEmpty(),
                uri.getQueryParameter("provider").orEmpty()
            )
            else -> errorJson("unknown path: ${uri.path}")
        }

    private fun profiles(): List<CliProfile> = runBlocking {
        val manager = app.appContainer.euiccChannelManager
        val result = mutableListOf<CliProfile>()
        manager.flowInternalEuiccPorts().collect { (slotId, portId) ->
            manager.flowEuiccSecureElements(slotId, portId).collect { seId ->
                manager.withEuiccChannel(slotId, portId, seId) { channel ->
                    val eid = channel.lpa.eID
                    channel.lpa.profiles.forEach { profile ->
                        result += CliProfile(
                            slotId = slotId,
                            portId = portId,
                            seId = seId.id,
                            logicalSlotId = channel.logicalSlotId,
                            eid = eid,
                            iccid = profile.iccid,
                            state = profile.state.name,
                            name = profile.name,
                            nickName = profile.nickName,
                            displayName = profile.displayName,
                            provider = profile.providerName,
                            profileClass = profile.profileClass.name
                        )
                    }
                }
            }
        }
        result
    }

    private fun profilesJson(): JSONArray =
        JSONArray().apply {
            profiles().forEach { put(it.toJson()) }
        }

    private fun profilesText(): String =
        buildString {
            profiles().forEach { p ->
                append("PROFILE name=\"")
                append(quoteText(p.displayName))
                append("\" state=\"")
                append(if (p.state == "Enabled") "已启用" else "已禁用")
                append("\" provider=\"")
                append(quoteText(p.provider))
                append("\" iccid=\"")
                append(quoteText(p.iccid))
                append("\" class=\"")
                append(quoteText(p.profileClass))
                append("\" slot=\"")
                append(p.slotId)
                append("\" port=\"")
                append(p.portId)
                append("\" se=\"")
                append(p.seId)
                append("\"\n")
            }
        }

    private fun switchProfileByTarget(target: String): JSONObject {
        val needle = target.lowercase()
        val matches = profiles().filter {
            it.iccid == target ||
                it.displayName.lowercase() == needle ||
                it.name.lowercase() == needle ||
                it.nickName.lowercase() == needle ||
                it.provider.lowercase() == needle ||
                it.displayName.lowercase().contains(needle) ||
                it.provider.lowercase().contains(needle)
        }
        return switchOne(matches, "target=$target")
    }

    private fun switchProfileExact(name: String, provider: String): JSONObject {
        val matches = profiles().filter {
            it.displayName == name && (provider.isEmpty() || it.provider == provider)
        }
        return switchOne(matches, "name=$name provider=$provider")
    }

    private fun switchProfileByIccid(iccid: String): JSONObject {
        val matches = profiles().filter { it.iccid == iccid }
        return switchOne(matches, "iccid=$iccid")
    }

    private fun switchOne(matches: List<CliProfile>, label: String): JSONObject =
        when (matches.size) {
            0 -> errorJson("profile not found: $label")
            1 -> enable(matches.single())
            else -> errorJson("ambiguous profile: $label").put("matches", JSONArray().apply {
                matches.forEach { put(it.toJson()) }
            })
        }

    private fun enable(profile: CliProfile): JSONObject = runBlocking {
        if (profile.state == "Enabled") {
            return@runBlocking okJson("already-enabled", profile)
        }

        val manager = app.appContainer.euiccChannelManager
        var refreshed = true
        val switched = manager.withEuiccChannel(
            profile.slotId,
            profile.portId,
            EuiccChannel.SecureElementId.createFromInt(profile.seId)
        ) { channel ->
            val refresh = app.appContainer.preferenceRepository.refreshAfterSwitchFlow.first()
            refreshed = refresh
            val ok = channel.lpa.switchProfile(profile.iccid, enable = true, refresh = refresh)
            if (ok || !refresh) {
                ok
            } else {
                refreshed = false
                channel.lpa.switchProfile(profile.iccid, enable = true, refresh = false)
            }
        }

        if (!switched) return@runBlocking errorJson("switch failed").put("profile", profile.toJson())

        if (refreshed) {
            try {
                manager.waitForReconnect(profile.slotId, profile.portId, timeoutMillis = 30000)
            } catch (e: Exception) {
                return@runBlocking okJson("switch-requested-reconnect-timeout", profile)
                    .put("verified", false)
                    .put("error", e.javaClass.simpleName)
            }
        }

        okJson("switched", profile).put("verified", true)
    }

    private fun okJson(message: String, profile: CliProfile): JSONObject =
        JSONObject()
            .put("ok", true)
            .put("message", message)
            .put("profile", profile.toJson())

    private fun errorJson(message: String): JSONObject =
        JSONObject().put("ok", false).put("error", message)

    private fun CliProfile.toJson(): JSONObject =
        JSONObject()
            .put("slotId", slotId)
            .put("portId", portId)
            .put("seId", seId)
            .put("logicalSlotId", logicalSlotId)
            .put("eid", eid)
            .put("iccid", iccid)
            .put("state", state)
            .put("name", name)
            .put("nickName", nickName)
            .put("displayName", displayName)
            .put("provider", provider)
            .put("class", profileClass)

    private fun quoteText(value: String): String =
        value.replace("\\", "\\\\").replace("\"", "\\\"")
}
