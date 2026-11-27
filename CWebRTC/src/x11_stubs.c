// No display on Linux: libwebrtc's typing detection asks X11 for the
// keyboard, and these answer that there's no display, so a program needs no
// libX11. Weak, so a program that links X11 itself gets the real ones.
__attribute__((weak)) void *XOpenDisplay(const char *name) {
    (void)name;
    return 0;
}

__attribute__((weak)) int XCloseDisplay(void *display) {
    (void)display;
    return 0;
}

__attribute__((weak)) int XQueryKeymap(void *display, char keys[32]) {
    (void)display;
    for (int i = 0; i < 32; i++) keys[i] = 0;
    return 1;
}
