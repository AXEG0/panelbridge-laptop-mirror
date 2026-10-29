namespace PanelMirror;

// Draws the game's frame rate into the top-left corner of a captured BGRA frame before it reaches the panel.
// In-game counters (Steam overlay, NVIDIA Alt+R, OptiScaler) don't show in exclusive fullscreen on the virtual
// display, but the mirror writes every pixel the panel shows.
static unsafe class FpsOverlay
{
    // 5x7 digits 0-9, one byte per row, bit 4 is the leftmost column.
    static readonly byte[] Digits =
    {
        0x0E, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0E,
        0x04, 0x0C, 0x04, 0x04, 0x04, 0x04, 0x0E,
        0x0E, 0x11, 0x01, 0x02, 0x04, 0x08, 0x1F,
        0x1F, 0x02, 0x04, 0x02, 0x01, 0x11, 0x0E,
        0x02, 0x06, 0x0A, 0x12, 0x1F, 0x02, 0x02,
        0x1F, 0x10, 0x1E, 0x01, 0x01, 0x11, 0x0E,
        0x06, 0x08, 0x10, 0x1E, 0x11, 0x11, 0x0E,
        0x1F, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08,
        0x0E, 0x11, 0x11, 0x0E, 0x11, 0x11, 0x0E,
        0x0E, 0x11, 0x11, 0x0F, 0x01, 0x02, 0x0C,
    };

    const int Scale = 3, Margin = 8, Pad = 2 * Scale;
    const uint Background = 0xFF000000, Foreground = 0xFF00FF00;

    public static void Draw(IntPtr pixels, uint pitch, int width, int height, int fps)
    {
        string text = Math.Clamp(fps, 0, 999).ToString();
        int stride = (int)pitch;
        int boxW = 2 * Pad + (text.Length * 6 - 1) * Scale, boxH = 2 * Pad + 7 * Scale;
        if (Margin + boxW > width || Margin + boxH > height) return;
        byte* origin = (byte*)pixels + Margin * stride + Margin * 4;
        for (int y = 0; y < boxH; y++)
            new Span<uint>(origin + y * stride, boxW).Fill(Background);
        for (int i = 0; i < text.Length; i++)
            for (int row = 0; row < 7; row++)
            {
                byte bits = Digits[(text[i] - '0') * 7 + row];
                for (int col = 0; col < 5; col++)
                {
                    if ((bits & (0x10 >> col)) == 0) continue;
                    byte* cell = origin + (Pad + row * Scale) * stride + (Pad + (i * 6 + col) * Scale) * 4;
                    for (int dy = 0; dy < Scale; dy++)
                        new Span<uint>(cell + dy * stride, Scale).Fill(Foreground);
                }
            }
    }
}
