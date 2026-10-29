# winui-kernel attribution

Original: Richasy/winui-kernel, commit 3f1086f6cfa8c1e0c3a64b930a8577dc5496c616.
https://github.com/Richasy/winui-kernel/tree/3f1086f6cfa8c1e0c3a64b930a8577dc5496c616

WindowBase and AppTitleBar C# files declare the MIT License in their headers.
Original source snapshots are included here for attribution and reproducibility;
they are not compiled directly. DesktopWindowFoundation.cs adapts WindowBase's
AppWindow/Mica setup, AppTitleBar's UpdateTheme and DPI-normalized native caption
insets, and the transparent XAML title-region pattern. It retains Yingyu's
existing host type and caption controls, uses its shipped icon and title, owns
and releases its event subscriptions, and paints the same selected background
brush in both root and title region to avoid separate material composition.
No Rodel Player closed-source code was obtained or copied.
