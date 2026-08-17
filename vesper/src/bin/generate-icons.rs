
use std::fs::File;
use std::path::Path;

fn load_png(path: &Path) -> std::io::Result<(u32, u32, Vec<u8>)> {
    let file = File::open(path)?;
    let decoder = png::Decoder::new(file);
    let mut reader = decoder.read_info()?;
    let info = reader.info();
    println!("Source image: {}x{}, {:?}, {:?}", info.width, info.height, info.color_type, info.bit_depth);

    let mut buf = vec![0; reader.output_buffer_size()];
    let info = reader.next_frame(&mut buf)?;
    let bytes = &buf[..info.buffer_size()];

    let mut rgba = Vec::with_capacity((info.width * info.height * 4) as usize);

    match info.color_type {
        png::ColorType::Rgba => {
            rgba.extend_from_slice(bytes);
        }
        png::ColorType::Rgb => {
            for chunk in bytes.chunks_exact(3) {
                rgba.push(chunk[0]);
                rgba.push(chunk[1]);
                rgba.push(chunk[2]);
                rgba.push(255);
            }
        }
        _ => {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                format!("Unsupported color type: {:?}", info.color_type)
            ));
        }
    }

    Ok((info.width, info.height, rgba))
}

fn resize_nearest(width: u32, height: u32, data: &[u8], new_w: u32, new_h: u32) -> Vec<u8> {
    let mut out = vec![0u8; (new_w * new_h * 4) as usize];
    let x_ratio = width as f32 / new_w as f32;
    let y_ratio = height as f32 / new_h as f32;

    for y in 0..new_h {
        for x in 0..new_w {
            let src_x = ((x as f32 + 0.5) * x_ratio) as u32;
            let src_y = ((y as f32 + 0.5) * y_ratio) as u32;
            let src_x_clamped = std::cmp::min(src_x, width - 1);
            let src_y_clamped = std::cmp::min(src_y, height - 1);
            let src_idx = (src_y_clamped * width + src_x_clamped) as usize * 4;
            let dst_idx = (y * new_w + x) as usize * 4;

            if src_idx + 3 < data.len() && dst_idx + 3 < out.len() {
                out[dst_idx] = data[src_idx];
                out[dst_idx + 1] = data[src_idx + 1];
                out[dst_idx + 2] = data[src_idx + 2];
                out[dst_idx + 3] = data[src_idx + 3];
            }
        }
    }
    out
}

fn is_white(r: u8, g: u8, b: u8) -> bool {
    r > 220 && g > 220 && b > 220
}

fn is_transparent(a: u8) -> bool {
    a < 50
}

fn recolor(data: &[u8], target_r: u8, target_g: u8, target_b: u8) -> Vec<u8> {
    let mut out = Vec::with_capacity(data.len());
    for chunk in data.chunks_exact(4) {
        let r = chunk[0];
        let g = chunk[1];
        let b = chunk[2];
        let a = chunk[3];

        if is_transparent(a) {
            out.push(r);
            out.push(g);
            out.push(b);
            out.push(a);
        } else if is_white(r, g, b) {
            out.push(r);
            out.push(g);
            out.push(b);
            out.push(a);
        } else {
            let gray = (r as u32 + g as u32 + b as u32) / 3;
            let factor = gray as f32 / 200.0;
            out.push((target_r as f32 * factor) as u8);
            out.push((target_g as f32 * factor) as u8);
            out.push((target_b as f32 * factor) as u8);
            out.push(a);
        }
    }
    out
}

fn save_png(path: &Path, width: u32, height: u32, data: &[u8]) -> std::io::Result<()> {
    let file = File::create(path)?;
    let mut encoder = png::Encoder::new(file, width, height);
    encoder.set_color(png::ColorType::Rgba);
    encoder.set_depth(png::BitDepth::Eight);
    let mut writer = encoder.write_header()?;
    writer.write_image_data(data)?;
    Ok(())
}

fn main() -> std::io::Result<()> {
    let manifest_dir = std::env::var("CARGO_MANIFEST_DIR").unwrap();
    let icons_dir = Path::new(&manifest_dir).join("extension").join("icons");
    let source_path = icons_dir.join("icon.png");

    if !source_path.exists() {
        eprintln!("Error: {:?} not found", source_path);
        std::process::exit(1);
    }

    let (w, h, data) = load_png(&source_path)?;

    let sizes = [16, 48, 128];
    let colors = [
        ("", (102, 126, 234)),      // 蓝色 - 未保存
        ("-green", (168, 230, 207)),  // 绿色 - 已保存
        ("-red", (255, 107, 107)),     // 红色 - 连不上后端
    ];

    for &size in &sizes {
        let resized = resize_nearest(w, h, &data, size, size);

        for (suffix, (r, g, b)) in &colors {
            let colored = recolor(&resized, *r, *g, *b);
            let path = icons_dir.join(format!("icon{}{}.png", size, suffix));
            save_png(&path, size, size, &colored)?;
            println!("Created {:?}", path);
        }
    }

    Ok(())
}
