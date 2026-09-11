package com.tommychang.c2pa_viewer

import android.content.ContentValues
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaMetadataRetriever
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import androidx.exifinterface.media.ExifInterface
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.math.BigInteger
import java.nio.charset.StandardCharsets
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.cert.X509Certificate
import java.security.spec.ECGenParameterSpec
import java.util.Date
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import org.bouncycastle.asn1.ASN1ObjectIdentifier
import org.bouncycastle.asn1.pkcs.PKCSObjectIdentifiers
import org.bouncycastle.asn1.x500.X500Name
import org.bouncycastle.asn1.x509.AlgorithmIdentifier
import org.bouncycastle.asn1.x509.BasicConstraints
import org.bouncycastle.asn1.x509.Extension
import org.bouncycastle.asn1.x509.ExtendedKeyUsage
import org.bouncycastle.asn1.x509.KeyPurposeId
import org.bouncycastle.asn1.x509.KeyUsage
import org.bouncycastle.cert.jcajce.JcaX509ExtensionUtils
import org.bouncycastle.cert.jcajce.JcaX509v3CertificateBuilder
import org.bouncycastle.operator.ContentSigner
import kotlin.math.roundToInt
import org.contentauth.c2pa.Builder
import org.contentauth.c2pa.BuilderIntent
import org.contentauth.c2pa.C2PA
import org.contentauth.c2pa.DigitalSourceType
import org.contentauth.c2pa.FileStream
import org.contentauth.c2pa.KeyStoreSigner
import org.contentauth.c2pa.Signer
import org.contentauth.c2pa.SigningAlgorithm
import org.json.JSONArray
import org.json.JSONObject

class MainActivity : FlutterActivity() {
    private companion object {
        const val CHANNEL_NAME = "c2pa_native"
        const val C2PA_KEY_ALIAS = "com.tommychang.perfectc2pa.c2pa-signer"
        const val C2PA_ISSUER_KEY_ALIAS = "com.tommychang.perfectc2pa.c2pa-issuer"
        const val C2PA_CLAIM_SIGNING_EKU = "1.3.6.1.4.1.62558.2.1"
        const val C2PA_FORMAT_UNKNOWN = "application/octet-stream"
        const val MAX_THUMBNAIL_SIZE = 512
        val C2PA_UUID = byteArrayOf(
            0xd8.toByte(), 0xfe.toByte(), 0xc3.toByte(), 0xd6.toByte(),
            0x1b.toByte(), 0x0e.toByte(), 0x48.toByte(), 0x3c.toByte(),
            0x92.toByte(), 0x97.toByte(), 0x58.toByte(), 0x28.toByte(),
            0x87.toByte(), 0x7e.toByte(), 0xc4.toByte(), 0x81.toByte(),
        )
        val EXIF_TAGS = mapOf(
            "Make" to ExifInterface.TAG_MAKE,
            "Model" to ExifInterface.TAG_MODEL,
            "DateTimeOriginal" to ExifInterface.TAG_DATETIME_ORIGINAL,
            "LensModel" to ExifInterface.TAG_LENS_MODEL,
            "FocalLength" to ExifInterface.TAG_FOCAL_LENGTH,
            "FocalLengthIn35mmFilm" to ExifInterface.TAG_FOCAL_LENGTH_IN_35MM_FILM,
            "ExposureTime" to ExifInterface.TAG_EXPOSURE_TIME,
            "FNumber" to ExifInterface.TAG_F_NUMBER,
            "PhotographicSensitivity" to ExifInterface.TAG_PHOTOGRAPHIC_SENSITIVITY,
            "Flash" to ExifInterface.TAG_FLASH,
            "Latitude" to ExifInterface.TAG_GPS_LATITUDE,
            "LatitudeRef" to ExifInterface.TAG_GPS_LATITUDE_REF,
            "Longitude" to ExifInterface.TAG_GPS_LONGITUDE,
            "LongitudeRef" to ExifInterface.TAG_GPS_LONGITUDE_REF,
            "Altitude" to ExifInterface.TAG_GPS_ALTITUDE,
            "AltitudeRef" to ExifInterface.TAG_GPS_ALTITUDE_REF,
        )
    }

    private val executor: ExecutorService = Executors.newSingleThreadExecutor()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL_NAME,
        ).setMethodCallHandler { call, result ->
            executor.execute {
                try {
                    val value = handle(call)
                    runOnUiThread { result.success(value) }
                } catch (error: Throwable) {
                    runOnUiThread {
                        result.error(
                            "C2PA_ANDROID_ERROR",
                            error.message ?: error.javaClass.simpleName,
                            error.stackTraceToString(),
                        )
                    }
                }
            }
        }
    }

    override fun onDestroy() {
        executor.shutdownNow()
        super.onDestroy()
    }

    private fun handle(call: MethodCall): Any? {
        return when (call.method) {
            "readManifest" -> readManifest(requireString(call, "path"))
            "readManifestWithResources" -> {
                readManifestWithResources(
                    requireString(call, "sourcePath"),
                    requireString(call, "outputDir"),
                )
            }
            "signFile" -> signFile(call)
            "thumbnailForMedia" -> thumbnailForMedia(requireString(call, "path"))
            "probeExifMetadata" -> probeExifMetadata(requireString(call, "path"))
            "saveToPhotoLibrary" -> saveToPhotoLibrary(requireString(call, "path"))
            "removeFile" -> removeFile(call)
            "pickOriginalMedia" -> throw UnsupportedOperationException(
                "Android uses the system document picker.",
            )
            else -> null
        }
    }

    private fun requireString(call: MethodCall, key: String): String =
        (call.arguments as? Map<*, *>)?.get(key) as? String
            ?: throw IllegalArgumentException("Missing $key")

    private fun readManifest(path: String): String? =
        runCatching { C2PA.readFile(path) }.getOrNull()

    private fun readManifestWithResources(path: String, outputDir: String): String? {
        val manifest = readManifest(path) ?: return null
        // The Android SDK returns the same manifest-store JSON as c2patool. The
        // media thumbnail is generated by Flutter separately, so no resource
        // extraction is needed for the current Android report UI.
        File(outputDir).mkdirs()
        return manifest
    }

    private fun signFile(call: MethodCall): Any? {
        val args = call.arguments as? Map<*, *>
            ?: throw IllegalArgumentException("Expected signFile arguments")
        val sourcePath = args["sourcePath"] as? String
            ?: throw IllegalArgumentException("Missing sourcePath")
        val outputPath = args["outputPath"] as? String
            ?: throw IllegalArgumentException("Missing outputPath")
        val mimeType = args["mimeType"] as? String
            ?: throw IllegalArgumentException("Missing mimeType")
        val mode = args["mode"] as? String ?: "add"
        val source = File(sourcePath)
        require(source.exists()) { "Source file not found: $sourcePath" }
        File(outputPath).parentFile?.mkdirs()

        val hasParent = mode == "add" && readManifest(sourcePath) != null
        val manifest = createManifest(source.name)
        Builder.fromJson(manifest).use { builder ->
            if (hasParent) {
                builder.setIntent(BuilderIntent.Edit)
                FileStream(source, FileStream.Mode.READ, createIfNeeded = false).use { ingredient ->
                    val ingredientJson = JSONObject()
                        .put("title", source.name)
                        .put("format", mimeType)
                        .put("relationship", "parentOf")
                        .toString()
                    builder.addIngredient(ingredientJson, mimeType, ingredient)
                }
            } else {
                builder.setIntent(BuilderIntent.Create(DigitalSourceType.DIGITAL_CREATION))
            }

            createKeyStoreSigner().use { signer ->
                FileStream(source, FileStream.Mode.READ, createIfNeeded = false).use { input ->
                    FileStream(File(outputPath), FileStream.Mode.WRITE).use { output ->
                        builder.sign(mimeType, input, output, signer)
                    }
                }
            }
        }
        return null
    }

    // The private key is generated once per app installation and never leaves
    // Android Keystore. The local issuer key is also kept there;
    // only the public leaf certificate is passed to c2pa-android.
    private fun createKeyStoreSigner(): Signer {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        ensureEcKey(keyStore, C2PA_KEY_ALIAS, "CN=Perfect C2PA Device Signer, O=Perfect C2PA, C=TW")
        ensureRsaKey(keyStore, C2PA_ISSUER_KEY_ALIAS, "CN=Perfect C2PA Local Issuer, O=Perfect C2PA, C=TW")
        val certificate = createC2paLeafCertificate(keyStore)
        return KeyStoreSigner.createSigner(
            algorithm = SigningAlgorithm.ES256,
            certificateChainPEM = certificate,
            keyAlias = C2PA_KEY_ALIAS,
        )
    }

    private fun ensureEcKey(keyStore: KeyStore, alias: String, subject: String) {
        if (keyStore.containsAlias(alias)) return
        val now = System.currentTimeMillis()
        val generator = KeyPairGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_EC,
            "AndroidKeyStore",
        )
        val spec = KeyGenParameterSpec.Builder(
            alias,
            KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY,
        )
            .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
            .setDigests(KeyProperties.DIGEST_SHA256)
            .setCertificateSubject(javax.security.auth.x500.X500Principal(subject))
            .setCertificateSerialNumber(BigInteger.valueOf(now))
            .setCertificateNotBefore(Date(now - 86_400_000L))
            .setCertificateNotAfter(Date(now + 365L * 86_400_000L))
            .setUserAuthenticationRequired(false)
            .build()
        generator.initialize(spec)
        generator.generateKeyPair()
    }

    private fun ensureRsaKey(keyStore: KeyStore, alias: String, subject: String) {
        if (keyStore.containsAlias(alias)) return
        val now = System.currentTimeMillis()
        val generator = KeyPairGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_RSA,
            "AndroidKeyStore",
        )
        val spec = KeyGenParameterSpec.Builder(
            alias,
            KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY,
        )
            .setKeySize(2048)
            .setDigests(KeyProperties.DIGEST_SHA256)
            .setSignaturePaddings(KeyProperties.SIGNATURE_PADDING_RSA_PKCS1)
            .setCertificateSubject(javax.security.auth.x500.X500Principal(subject))
            .setCertificateSerialNumber(BigInteger.valueOf(now))
            .setCertificateNotBefore(Date(now - 86_400_000L))
            .setCertificateNotAfter(Date(now + 365L * 86_400_000L))
            .setUserAuthenticationRequired(false)
            .build()
        generator.initialize(spec)
        generator.generateKeyPair()
    }

    private fun createC2paLeafCertificate(keyStore: KeyStore): String {
        val leafEntry = keyStore.getEntry(C2PA_KEY_ALIAS, null) as? KeyStore.PrivateKeyEntry
            ?: throw IllegalStateException("Android Keystore C2PA key is unavailable")
        val issuerEntry = keyStore.getEntry(C2PA_ISSUER_KEY_ALIAS, null) as? KeyStore.PrivateKeyEntry
            ?: throw IllegalStateException("Android Keystore issuer key is unavailable")
        val issuerCertificate = issuerEntry.certificate as? X509Certificate
            ?: throw IllegalStateException("Android Keystore issuer certificate is unavailable")
        val now = System.currentTimeMillis()
        val leafSubject = X500Name(
            "CN=Perfect C2PA Device Signer, O=Perfect C2PA, OU=Android, C=TW",
        )
        val issuer = X500Name(issuerCertificate.subjectX500Principal.name)
        val builder = JcaX509v3CertificateBuilder(
            issuer,
            BigInteger.valueOf(now),
            Date(now - 86_400_000L),
            Date(now + 365L * 86_400_000L),
            leafSubject,
            leafEntry.certificate.publicKey,
        )
        val extensionUtils = JcaX509ExtensionUtils()
        builder.addExtension(Extension.basicConstraints, true, BasicConstraints(false))
        builder.addExtension(Extension.keyUsage, true, KeyUsage(KeyUsage.digitalSignature))
        builder.addExtension(
            Extension.extendedKeyUsage,
            false,
            ExtendedKeyUsage(
                KeyPurposeId.getInstance(ASN1ObjectIdentifier(C2PA_CLAIM_SIGNING_EKU)),
            ),
        )
        builder.addExtension(
            Extension.subjectKeyIdentifier,
            false,
            extensionUtils.createSubjectKeyIdentifier(leafEntry.certificate.publicKey),
        )
        builder.addExtension(
            Extension.authorityKeyIdentifier,
            false,
            extensionUtils.createAuthorityKeyIdentifier(issuerCertificate),
        )
        val certificate = builder.build(
            AndroidKeyStoreContentSigner(issuerEntry.privateKey),
        )
        return certificate.toPem()
    }

    private fun removeFile(call: MethodCall): Any? {
        val sourcePath = requireString(call, "sourcePath")
        val outputPath = requireString(call, "outputPath")
        val source = File(sourcePath)
        val output = File(outputPath)
        require(source.exists()) { "Source file not found: $sourcePath" }
        output.parentFile?.mkdirs()

        when (source.extension.lowercase()) {
            "mp4", "mov", "heic" -> removeC2paFromIsoBmff(source, output)
            else -> removeC2paFromImage(source, output)
        }
        return null
    }

    // Match the iOS behavior: image re-encoding omits EXIF, XMP, and C2PA.
    private fun removeC2paFromImage(source: File, output: File) {
        val bitmap = BitmapFactory.decodeFile(source.path)
            ?: throw IllegalArgumentException("Could not decode image: ${source.name}")
        val format = when (source.extension.lowercase()) {
            "png" -> Bitmap.CompressFormat.PNG
            "webp" -> Bitmap.CompressFormat.WEBP
            else -> Bitmap.CompressFormat.JPEG
        }
        try {
            FileOutputStream(output).use { stream ->
                check(bitmap.compress(format, 100, stream)) {
                    "Could not write stripped image: ${output.name}"
                }
            }
        } finally {
            bitmap.recycle()
        }
    }

    // MP4/MOV/HEIC carry the C2PA manifest in a top-level UUID box. Strip only
    // that box so the encoded media and its other metadata remain intact.
    private fun removeC2paFromIsoBmff(source: File, output: File) {
        RandomAccessFile(source, "r").use { input ->
            FileOutputStream(output).use { stream ->
                val fileLength = input.length()
                val buffer = ByteArray(64 * 1024)
                var offset = 0L
                while (offset < fileLength) {
                    require(fileLength - offset >= 8) { "Malformed ISO-BMFF file" }
                    input.seek(offset)
                    val size32 = input.readInt().toLong() and 0xffffffffL
                    val typeBytes = ByteArray(4)
                    input.readFully(typeBytes)
                    val type = String(typeBytes, StandardCharsets.US_ASCII)
                    var headerSize = 8L
                    val boxSize = when (size32) {
                        0L -> fileLength - offset
                        1L -> {
                            require(fileLength - offset >= 16) {
                                "Malformed extended ISO-BMFF box"
                            }
                            headerSize = 16L
                            input.readLong()
                        }
                        else -> size32
                    }
                    require(boxSize >= headerSize && boxSize <= fileLength - offset) {
                        "Malformed ISO-BMFF box"
                    }

                    val isC2pa = if (type == "uuid" && boxSize >= headerSize + C2PA_UUID.size) {
                        val uuid = ByteArray(C2PA_UUID.size)
                        input.readFully(uuid)
                        uuid.contentEquals(C2PA_UUID)
                    } else {
                        type == "c2pa"
                    }
                    if (!isC2pa) {
                        input.seek(offset)
                        copyBytes(input, stream, boxSize, buffer)
                    }
                    offset += boxSize
                }
            }
        }
    }

    private fun copyBytes(
        input: RandomAccessFile,
        output: FileOutputStream,
        count: Long,
        buffer: ByteArray,
    ) {
        var remaining = count
        while (remaining > 0) {
            val read = input.read(buffer, 0, minOf(buffer.size.toLong(), remaining).toInt())
            require(read > 0) { "Unexpected end of ISO-BMFF file" }
            output.write(buffer, 0, read)
            remaining -= read
        }
    }

    private fun ByteArray.toPem(): String {
        val encoded = Base64.encodeToString(this, Base64.NO_WRAP)
        return buildString {
            append("-----BEGIN CERTIFICATE-----\n")
            encoded.chunked(64).forEach { append(it).append('\n') }
            append("-----END CERTIFICATE-----\n")
        }
    }

    private fun org.bouncycastle.cert.X509CertificateHolder.toPem(): String =
        encoded.toPem()

    private class AndroidKeyStoreContentSigner(
        private val privateKey: java.security.PrivateKey,
    ) : ContentSigner {
        private val output = java.io.ByteArrayOutputStream()

        override fun getAlgorithmIdentifier(): AlgorithmIdentifier =
            AlgorithmIdentifier(PKCSObjectIdentifiers.sha256WithRSAEncryption)

        override fun getOutputStream(): java.io.OutputStream = output

        override fun getSignature(): ByteArray {
            val signature = java.security.Signature.getInstance("SHA256withRSA")
            signature.initSign(privateKey)
            signature.update(output.toByteArray())
            return signature.sign()
        }
    }

    private fun createManifest(title: String): String =
        JSONObject()
            .put("claim_generator", "Perfect C2PA")
            .put("title", title)
            .put(
                "assertions",
                JSONArray().put(
                    JSONObject()
                        .put("label", "c2pa.actions.v2")
                        .put(
                            "data",
                            JSONObject().put(
                                "actions",
                                JSONArray().put(
                                    JSONObject()
                                        .put("action", "c2pa.edited")
                                        .put("softwareAgent", "Perfect C2PA"),
                                ),
                            ),
                        ),
                ),
            )
            .toString()

    private fun thumbnailForMedia(path: String): ByteArray? {
        val extension = File(path).extension.lowercase()
        val bitmap = if (extension == "mp4" || extension == "mov") {
            val retriever = MediaMetadataRetriever()
            try {
                retriever.setDataSource(path)
                retriever.getFrameAtTime(0)
            } finally {
                retriever.release()
            }
        } else {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(path, bounds)
            val sample = calculateSampleSize(bounds.outWidth, bounds.outHeight)
            BitmapFactory.decodeFile(path, BitmapFactory.Options().apply {
                inSampleSize = sample
                inPreferredConfig = Bitmap.Config.ARGB_8888
            })
        } ?: return null

        val scaled = scaleBitmap(bitmap)
        return try {
            java.io.ByteArrayOutputStream().use { output ->
                scaled.compress(Bitmap.CompressFormat.JPEG, 85, output)
                output.toByteArray()
            }
        } finally {
            if (scaled !== bitmap) scaled.recycle()
            bitmap.recycle()
        }
    }

    private fun calculateSampleSize(width: Int, height: Int): Int {
        var sample = 1
        while (width / sample > MAX_THUMBNAIL_SIZE || height / sample > MAX_THUMBNAIL_SIZE) {
            sample *= 2
        }
        return sample
    }

    private fun scaleBitmap(bitmap: Bitmap): Bitmap {
        val largest = maxOf(bitmap.width, bitmap.height)
        if (largest <= MAX_THUMBNAIL_SIZE) return bitmap
        val scale = MAX_THUMBNAIL_SIZE.toFloat() / largest
        return Bitmap.createScaledBitmap(
            bitmap,
            (bitmap.width * scale).roundToInt(),
            (bitmap.height * scale).roundToInt(),
            true,
        )
    }

    private fun probeExifMetadata(path: String): Map<String, Map<String, String>> {
        if (File(path).extension.lowercase() in setOf("mp4", "mov")) {
            return emptyMap()
        }
        val exif = ExifInterface(path)
        val values = EXIF_TAGS.mapNotNull { (name, tag) ->
            exif.getAttribute(tag)?.takeIf { it.isNotBlank() }?.let { name to it }
        }.toMap()
        return if (values.isEmpty()) emptyMap() else mapOf("EXIF" to values)
    }

    private fun saveToPhotoLibrary(path: String): Any? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            throw UnsupportedOperationException(
                "Saving directly to the media library requires Android 10 or newer.",
            )
        }
        val source = File(path)
        require(source.exists()) { "Signed file not found: $path" }
        val mimeType = mimeTypeFor(source)
        val isVideo = mimeType.startsWith("video/")
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, source.name)
            put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
            put(
                MediaStore.MediaColumns.RELATIVE_PATH,
                (if (isVideo) Environment.DIRECTORY_MOVIES else Environment.DIRECTORY_PICTURES) +
                    "/Perfect C2PA",
            )
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val uri = contentResolver.insert(
            if (isVideo) {
                MediaStore.Video.Media.EXTERNAL_CONTENT_URI
            } else {
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI
            },
            values,
        ) ?: throw IllegalStateException("Could not create a media library entry")
        try {
            contentResolver.openOutputStream(uri)?.use { output ->
                source.inputStream().use { input -> input.copyTo(output) }
            } ?: throw IllegalStateException("Could not open media library entry")
            contentResolver.update(
                uri,
                ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) },
                null,
                null,
            )
        } catch (error: Throwable) {
            contentResolver.delete(uri, null, null)
            throw error
        }
        return null
    }

    private fun mimeTypeFor(file: File): String = when (file.extension.lowercase()) {
        "jpg", "jpeg" -> "image/jpeg"
        "png" -> "image/png"
        "webp" -> "image/webp"
        "tif", "tiff" -> "image/tiff"
        "heic" -> "image/heic"
        "mp4" -> "video/mp4"
        "mov" -> "video/quicktime"
        else -> C2PA_FORMAT_UNKNOWN
    }
}
