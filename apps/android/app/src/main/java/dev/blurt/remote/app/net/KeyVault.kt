// Where the paired keys live (the iPhone's Keychain, "this device only"). An AES-256-GCM key made in the Android Keystore, which never leaves
// it, wraps each computer's 32-byte key; the wrapped bytes sit in app-private storage that backups leave out (res/xml/backup_rules.xml,
// data_extraction_rules.xml). Restored onto another phone they'd be worthless anyway: the Keystore key doesn't travel.
package dev.blurt.remote.app.net

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class KeyVault(c: Context) {
    private val store = c.getSharedPreferences("vault", Context.MODE_PRIVATE)

    private fun master(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        val g = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        g.init(KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .build())
        return g.generateKey()
    }

    @Synchronized fun store(key: ByteArray, account: String) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, master())
        val sealed = cipher.iv + cipher.doFinal(key)
        store.edit().putString(account, Base64.encodeToString(sealed, Base64.NO_WRAP)).commit()
    }

    @Synchronized fun read(account: String): ByteArray? {
        val s = store.getString(account, null) ?: return null
        return runCatching {
            val b = Base64.decode(s, Base64.NO_WRAP)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, master(), GCMParameterSpec(128, b, 0, 12))
            cipher.doFinal(b, 12, b.size - 12)
        }.getOrNull()
    }

    @Synchronized fun remove(account: String) { store.edit().remove(account).commit() }

    private companion object { const val ALIAS = "blurt.remote.vault" }
}
