-keepattributes *Annotation*
-keepclassmembers class **$$serializer { *; }
-keep,includedescriptorclasses class net.sukavinagroup.user.data.**$$serializer { *; }

# WorkManager opens its generated Room database implementation through reflection
# during the AndroidX Startup phase. Keep its constructor in release builds;
# otherwise R8 can remove it and the application crashes before MainActivity.
-keep class androidx.work.impl.WorkDatabase_Impl {
    <init>();
}

# Tink uses Error Prone annotations only during compilation. They are not needed
# at runtime, so R8 can safely ignore their optional class references.
-dontwarn com.google.errorprone.annotations.**
