use std::ffi::c_void;

extern "C" {
    fn pjglib_init_streams(
        in_src: *mut c_void,
        in_type: i32,
        in_size: i32,
        out_dest: *mut c_void,
        out_type: i32,
    );
    fn pjglib_convert_stream2mem(
        out_file: *mut *mut u8,
        out_size: *mut u32,
        msg: *mut u8,
    ) -> bool;
}

const MSG_SIZE: usize = 256;

fn call(input: &[u8]) -> Result<Vec<u8>, String> {
    let mut out_ptr: *mut u8 = std::ptr::null_mut();
    let mut out_len: u32 = 0;
    let mut msg = [0u8; MSG_SIZE];

    unsafe {
        pjglib_init_streams(
            input.as_ptr() as *mut c_void,
            1,                        // in_type=1: memory input
            input.len() as i32,
            std::ptr::null_mut(),
            1,                        // out_type=1: memory output (allocated by packJPG)
        );
        let ok = pjglib_convert_stream2mem(
            &mut out_ptr,
            &mut out_len,
            msg.as_mut_ptr(),
        );
        if !ok || out_ptr.is_null() {
            let end = msg.iter().position(|&b| b == 0).unwrap_or(MSG_SIZE);
            return Err(String::from_utf8_lossy(&msg[..end]).into_owned());
        }
        // packJPG allocates the output buffer via malloc; copy then free.
        let bytes = std::slice::from_raw_parts(out_ptr, out_len as usize).to_vec();
        libc::free(out_ptr as *mut c_void);
        Ok(bytes)
    }
}

/// Encode JPEG bytes → PJG bytes.
pub fn jpg_to_pjg(jpg: &[u8]) -> Result<Vec<u8>, String> {
    if jpg.len() < 2 || &jpg[..2] != b"\xff\xd8" {
        return Err("not a JPEG (missing SOI marker)".into());
    }
    call(jpg)
}

/// Decode PJG bytes → JPEG bytes.
pub fn pjg_to_jpg(pjg: &[u8]) -> Result<Vec<u8>, String> {
    call(pjg)
}
