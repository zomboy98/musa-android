# Ignore missing Play Core classes (not used, but referenced by Flutter)
-dontwarn com.google.android.play.core.splitcompat.**
-dontwarn com.google.android.play.core.splitinstall.**
-dontwarn com.google.android.play.core.tasks.**

# Ignore missing javax.xml.stream (not used on Android)
-dontwarn javax.xml.stream.**

# The FFmpeg plugin ships its JNI keep rules in its AAR.

# UniFFI/JNA resolves FFI methods and structure fields by their generated names.
# Preserve the generated Rust bindings used by JNA.
-keep class com.sun.jna.** { *; }
-keep class com.mornye.backend.** { *; }
# JNA's desktop AWT helpers are unavailable and unused on Android.
# https://github.com/java-native-access/jna/blob/master/www/FrequentlyAskedQuestions.md#jna-on-android
-dontwarn java.awt.Component
-dontwarn java.awt.GraphicsEnvironment
-dontwarn java.awt.HeadlessException
-dontwarn java.awt.Window

-keepclasseswithmembernames class * {
    native <methods>;
}

# Kotlin coroutines - expanded rules
-keepnames class kotlinx.coroutines.internal.MainDispatcherFactory {}
-keepnames class kotlinx.coroutines.CoroutineExceptionHandler {}
-keepclassmembers class kotlinx.coroutines.** {
    volatile <fields>;
}
-keepclassmembernames class kotlinx.** {
    volatile <fields>;
}
-dontwarn kotlinx.coroutines.**

# Runtime annotations used by serializers and generated bindings.
-keepattributes RuntimeVisibleAnnotations,AnnotationDefault
-dontwarn kotlin.**

# Android instantiates these components from the manifest. Preserve only their
# names and constructors; normal reachability can now shrink/optimize helpers,
# coroutine state machines, and unused members in the rest of the app package.
-keep,allowoptimization class com.zarz.mornye.MainActivity {
    public <init>();
}
-keep,allowoptimization class com.zarz.mornye.DownloadService {
    public <init>();
}
-keep,allowoptimization class com.zarz.mornye.DownloadQueueWidgetProvider {
    public <init>();
}

# Flutter's fragment builders instantiate this class through reflection.
-keep,allowoptimization class com.zarz.mornye.MainActivity$ImpellerAwareFlutterFragment {
    public <init>();
}

-keepattributes *Annotation*
-keepattributes SourceFile,LineNumberTable
-keepattributes Signature
-keepattributes Exceptions
-keepattributes InnerClasses
-keepattributes EnclosingMethod

# Flutter invokes the generated registrant by name. Individual plugins are
# referenced by this class and retain their own consumer rules.
-keep class io.flutter.plugins.GeneratedPluginRegistrant { *; }

# Cast framework resolves its options provider by the class name in the manifest.
-keep class com.zarz.mornye.MornyeCastOptionsProvider { public <init>(); }

# JNA looks up Structure fields, Callback methods and library interfaces by name.
-keep class * extends com.sun.jna.Structure { *; }
-keep class * implements com.sun.jna.Callback { *; }
-keep class * extends com.sun.jna.Library { *; }
-keepclassmembers class * extends com.sun.jna.** { public *; }
-keep class uniffi.** { *; }
-dontwarn com.sun.jna.**

# Native library entry points reachable only through JNI.
-keep class com.zarz.mornye.NativeAudio { *; }

# Hide verbose and informational logging from release builds.
-assumenosideeffects class android.util.Log {
    public static int v(...);
    public static int d(...);
    public static int i(...);
}

# Do not expose original source file names in stack traces.
-renamesourcefileattribute SourceFile

# Room instantiates the generated database through its no-argument constructor
# (WorkManager's WorkDatabase_Impl included).
-keep class * extends androidx.room.RoomDatabase { <init>(); }
-keep class androidx.work.impl.WorkDatabase_Impl { <init>(); }

# App Startup and WorkManager create these classes by name.
-keep class * extends androidx.startup.Initializer { <init>(); }
-keep class * extends androidx.work.ListenableWorker {
    public <init>(android.content.Context, androidx.work.WorkerParameters);
}
