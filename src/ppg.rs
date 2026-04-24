extern "C" {
    fn ppglib_compress(
        in_data: *const u8,
        in_size: u32,
        out_data: *mut *mut u8,
        out_size: *mut u32,
    ) -> bool;
    fn ppglib_decompress(
        in_data: *const u8,
        in_size: u32,
        out_data: *mut *mut u8,
        out_size: *mut u32,
    ) -> bool;
    fn ppglib_free(ptr: *mut u8);
}

pub fn png_to_ppg(png: &[u8]) -> Result<Vec<u8>, String> {
    let mut out_data: *mut u8 = std::ptr::null_mut();
    let mut out_size: u32 = 0;
    let ok = unsafe {
        ppglib_compress(
            png.as_ptr(),
            png.len() as u32,
            &mut out_data,
            &mut out_size,
        )
    };
    if !ok || out_data.is_null() {
        return Err("packPNG compress failed".into());
    }
    let result =
        unsafe { std::slice::from_raw_parts(out_data, out_size as usize).to_vec() };
    unsafe { ppglib_free(out_data) };
    Ok(result)
}

pub fn ppg_to_png(ppg: &[u8]) -> Result<Vec<u8>, String> {
    let mut out_data: *mut u8 = std::ptr::null_mut();
    let mut out_size: u32 = 0;
    let ok = unsafe {
        ppglib_decompress(
            ppg.as_ptr(),
            ppg.len() as u32,
            &mut out_data,
            &mut out_size,
        )
    };
    if !ok || out_data.is_null() {
        return Err("packPNG decompress failed".into());
    }
    let result =
        unsafe { std::slice::from_raw_parts(out_data, out_size as usize).to_vec() };
    unsafe { ppglib_free(out_data) };
    Ok(result)
}
