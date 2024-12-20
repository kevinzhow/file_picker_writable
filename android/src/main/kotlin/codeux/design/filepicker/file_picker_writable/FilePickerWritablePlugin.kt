package codeux.design.filepicker.file_picker_writable

import android.app.Activity
import android.net.Uri
import android.util.Log
import androidx.annotation.MainThread
import androidx.annotation.NonNull
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import java.io.File
import java.io.PrintWriter
import java.io.StringWriter
import java.util.*
import kotlinx.coroutines.*

private const val TAG = "FilePickerWritable"

/** FilePickerWritablePlugin */
class FilePickerWritablePlugin :
        FlutterPlugin,
        MethodCallHandler,
        ActivityAware,
        ActivityProvider,
        CoroutineScope by MainScope() {
  /// The MethodChannel that will the communication between Flutter and native Android
  ///
  /// This local reference serves to register the plugin with the Flutter Engine and unregister it
  /// when the Flutter Engine is detached from the Activity
  private lateinit var channel: MethodChannel
  private val impl: FilePickerWritableImpl = FilePickerWritableImpl(this)
  private var currentBinding: ActivityPluginBinding? = null

  private val eventQueue = LinkedList<Map<String, String>>()
  private var eventSink: EventChannel.EventSink? = null

  override fun onAttachedToEngine(
          @NonNull flutterPluginBinding: FlutterPlugin.FlutterPluginBinding
  ) {
    initializePlugin(flutterPluginBinding.binaryMessenger)
  }

  private fun initializePlugin(binaryMessenger: BinaryMessenger) {
    channel = MethodChannel(binaryMessenger, "design.codeux.file_picker_writable")
    channel.setMethodCallHandler(this)
    EventChannel(binaryMessenger, "design.codeux.file_picker_writable/events")
            .setStreamHandler(
                    object : EventChannel.StreamHandler {
                      override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                        eventSink = events
                        launch(Dispatchers.Main) {
                          while (true) {
                            val event = eventQueue.poll() ?: break
                            eventSink?.success(event)
                          }
                        }
                      }

                      override fun onCancel(arguments: Any?) {
                        eventSink = null
                      }
                    }
            )
  }

  override fun onMethodCall(@NonNull call: MethodCall, @NonNull result: Result) {
    launch(Dispatchers.Main) {
      logDebug("Got method call: ${call.method}")
      try {
        when (call.method) {
          "init" -> {
            impl.init()
          }
          "openFilePicker" -> {
            val allowedExtensions =
                    call.argument<String>("allowedExtensions")
                            ?: throw FilePickerException("Expected argument 'allowedExtensions'")
            impl.openFilePicker(result, allowedExtensions)
          }
          "openFilePickerForCreate" -> {
            val path =
                    call.argument<String>("path")
                            ?: throw FilePickerException("Expected argument 'path'")
            impl.openFilePickerForCreate(result, path)
          }
          "readFileWithIdentifier" -> {
            val identifier =
                    call.argument<String>("identifier")
                            ?: throw FilePickerException("Expected argument 'identifier'")
            impl.readFileWithIdentifier(result, identifier)
          }
          "writeFileWithIdentifier" -> {
            val identifier =
                    call.argument<String>("identifier")
                            ?: throw FilePickerException("Expected argument 'identifier'")
            val path =
                    call.argument<String>("path")
                            ?: throw FilePickerException("Expected argument 'path'")
            impl.writeFileWithIdentifier(result, identifier, File(path))
          }
          "closeFileWithIdentifier" -> {
            val identifier =
                    call.argument<String>("identifier")
                            ?: throw FilePickerException("Expected argument 'identifier'")
            impl.closeFileWithIdentifier(result, identifier)
          }
          "disposeIdentifier" -> {
            val identifier =
                    call.argument<String>("identifier")
                            ?: throw FilePickerException("Expected argument 'identifier'")
            impl.disposeIdentifier(identifier)
            result.success(null)
          }
          "disposeAllIdentifiers" -> {
            impl.disposeAllIdentifiers()
            result.success(null)
          }
          else -> {
            result.notImplemented()
          }
        }
      } catch (e: Exception) {
        logDebug("Error while handling method call $call", e)
        result.error("FilePickerError", e.toString(), null)
      }
    }
  }

  override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
    channel.setMethodCallHandler(null)
    cancel("onDetachedFromEngine")
  }

  override fun onDetachedFromActivity() {
    currentBinding?.let { impl.onDetachedFromActivity(it) }
    currentBinding = null
  }

  override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
    currentBinding = binding
    impl.onAttachedToActivity(binding)
  }

  override fun onAttachedToActivity(binding: ActivityPluginBinding) {
    currentBinding = binding
    impl.onAttachedToActivity(binding)
  }

  override fun onDetachedFromActivityForConfigChanges() {
    currentBinding?.let { impl.onDetachedFromActivity(it) }
    currentBinding = null
  }

  override val activity: Activity?
    get() = currentBinding?.activity

  override fun logDebug(message: String, e: Throwable?) {
    Log.d(TAG, message, e)
    val exception =
            e?.let {
              "${e.localizedMessage}\n" +
                      StringWriter().also { e.printStackTrace(PrintWriter(it)) }.toString()
            }
                    ?: ""
    sendEvent(
            mapOf(
                    "type" to "log",
                    "level" to "debug",
                    "message" to "${Thread.currentThread().name} $message",
                    "exception" to exception
            )
    )
  }

  @MainThread
  override fun openFile(fileInfo: Map<String, String>) {
    channel.invokeMethod("openFile", fileInfo)
  }

  @MainThread
  override fun handleOpenUri(uri: Uri) {
    channel.invokeMethod("handleUri", uri.toString())
  }

  private fun sendEvent(event: Map<String, String>) {
    launch(Dispatchers.Main) { eventSink?.success(event) ?: eventQueue.add(event) }
  }
}
