from PIL import Image, ImageDraw
import os

def generate_icons():
    dir_path = os.path.dirname(os.path.abspath(__file__))
    sizes = [16, 32, 48, 64, 128, 256]
    images = []

    for size in sizes:
        img = Image.new('RGBA', (size, size), (0, 0, 0, 0))
        d = ImageDraw.Draw(img)

        # Scale factor
        s = size / 64.0
        r = max(2, int(14 * s))

        # Teal background rounded rectangle
        d.rounded_rectangle([int(2 * s), int(2 * s), int(61 * s), int(61 * s)], radius=r, fill=(0, 173, 181, 255))

        # Clipboard board
        d.rounded_rectangle([int(18 * s), int(18 * s), int(46 * s), int(52 * s)], radius=max(1, int(4 * s)), fill=(255, 255, 255, 255))
        # Clip top
        d.rounded_rectangle([int(24 * s), int(12 * s), int(40 * s), int(20 * s)], radius=max(1, int(3 * s)), fill=(34, 35, 54, 255))
        # Inner lines
        d.rectangle([int(23 * s), int(27 * s), int(41 * s), int(30 * s)], fill=(0, 173, 181, 255))
        d.rectangle([int(23 * s), int(34 * s), int(41 * s), int(37 * s)], fill=(0, 173, 181, 255))
        d.rectangle([int(23 * s), int(41 * s), int(35 * s), int(44 * s)], fill=(0, 173, 181, 255))

        images.append(img)

    # Save highest resolution PNG
    png_path = os.path.join(dir_path, 'icon.png')
    images[-1].save(png_path)

    # Save multi-size ICO
    ico_path = os.path.join(dir_path, 'icon.ico')
    images[0].save(ico_path, format='ICO', sizes=[(s, s) for s in sizes], append_images=images[1:])
    print(f"Generated {ico_path} and {png_path}")

if __name__ == '__main__':
    generate_icons()

