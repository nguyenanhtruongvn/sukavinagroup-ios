-keepattributes *Annotation*
-keepclassmembers class **$$serializer { *; }
-keep,includedescriptorclasses class net.sukavinagroup.user.data.**$$serializer { *; }

# Tink uses Error Prone annotations only during compilation. They are not needed
# at runtime, so R8 can safely ignore their optional class references.
-dontwarn com.google.errorprone.annotations.**
