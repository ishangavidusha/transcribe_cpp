# capture_jni.c binds AudioCapture's native methods by symbol name
# (Java_com_transcribecpp_transcribe_1cpp_AudioCapture_native*), so neither
# the class nor those methods may be renamed or removed. Flutter's default
# rules happen to cover this; an app with its own shrinker configuration
# might not, and a renamed method fails only when the microphone starts.
-keepclasseswithmembernames,includedescriptorclasses class com.transcribecpp.transcribe_cpp.AudioCapture {
    native <methods>;
}
