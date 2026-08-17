#!/usr/bin/env python3
"""Generate colored icons for the extension using PIL."""

import os

try:
    from PIL import Image, ImageDraw
    HAS_PIL = True
except ImportError:
    HAS_PIL = False


def draw_icon(img, color):
    draw = ImageDraw.Draw(img)
    size = img.width
    margin = size // 8
    radius = size // 6

    draw.rounded_rectangle(
        [margin, margin, size - margin, size - margin],
        radius=radius,
        fill=color
    )

    book_margin = size // 4
    book_color = (255, 255, 255)

    draw.rectangle(
        [book_margin, book_margin, book_margin + size // 10, size - book_margin],
        fill=book_color
    )

    draw.rectangle(
        [book_margin + size // 10 + 2, book_margin, size - book_margin, size - book_margin],
        fill=book_color
    )


def generate_icons():
    icons_dir = os.path.join(os.path.dirname(__file__), 'extension', 'icons')
    os.makedirs(icons_dir, exist_ok=True)

    sizes = [16, 48, 128]

    if HAS_PIL:
        blue = (102, 126, 234)
        green = (168, 230, 207)

        for size in sizes:
            # Blue icon (unsaved)
            img = Image.new('RGBA', (size, size), (0, 0, 0, 0))
            draw_icon(img, blue)
            img.save(os.path.join(icons_dir, f'icon{size}.png'))
            print(f'Created icon{size}.png (blue)')

            # Green icon (saved)
            img = Image.new('RGBA', (size, size), (0, 0, 0, 0))
            draw_icon(img, green)
            img.save(os.path.join(icons_dir, f'icon{size}-green.png'))
            print(f'Created icon{size}-green.png (green)')
    else:
        print("PIL not available, creating placeholder files...")
        import base64

        png_bytes = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==')

        for size in sizes:
            for suffix in ['', '-green']:
                path = os.path.join(icons_dir, f'icon{size}{suffix}.png')
                with open(path, 'wb') as f:
                    f.write(png_bytes)
                print(f'Created placeholder icon{size}{suffix}.png')

        print("\nTo get colored icons, install Pillow:")
        print("  pip install Pillow")
        print("Then run: python3 generate-icons.py")


if __name__ == '__main__':
    generate_icons()
