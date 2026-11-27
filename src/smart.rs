use serde_json::{Value, json};
use std::fs::File;
use std::io;
use std::mem::{offset_of, size_of};
use std::os::windows::io::{AsRawHandle, FromRawHandle};
use std::ptr::{null, null_mut};
use windows_sys::Win32::Foundation::INVALID_HANDLE_VALUE;
use windows_sys::Win32::Storage::FileSystem::{
    BusTypeAta, BusTypeFileBackedVirtual, BusTypeNvme, BusTypeRAID, BusTypeSas, BusTypeSata,
    BusTypeScsi, BusTypeSpaces, BusTypeUsb, BusTypeVirtual, CreateFileW, FILE_SHARE_READ,
    FILE_SHARE_WRITE, OPEN_EXISTING, QueryDosDeviceW,
};
use windows_sys::Win32::Storage::Nvme::NVME_LOG_PAGE_HEALTH_INFO;
use windows_sys::Win32::System::IO::DeviceIoControl;
use windows_sys::Win32::System::Ioctl::{
    DISK_GEOMETRY_EX, IOCTL_DISK_GET_DRIVE_GEOMETRY_EX, IOCTL_STORAGE_PREDICT_FAILURE,
    IOCTL_STORAGE_QUERY_PROPERTY, NVMeDataTypeLogPage, ProtocolTypeNvme, STORAGE_DEVICE_DESCRIPTOR,
    STORAGE_PREDICT_FAILURE, STORAGE_PROPERTY_QUERY, STORAGE_PROTOCOL_DATA_DESCRIPTOR,
    STORAGE_PROTOCOL_SPECIFIC_DATA, STORAGE_TEMPERATURE_DATA_DESCRIPTOR, STORAGE_TEMPERATURE_INFO,
    StorageDeviceProperty, StorageDeviceProtocolSpecificProperty, StorageDeviceTemperatureProperty,
};

const LOG_BYTES: usize = 512;
const QUERY_HEADER: usize = offset_of!(STORAGE_PROPERTY_QUERY, AdditionalParameters);
const PROTOCOL_OFFSET: usize = offset_of!(STORAGE_PROTOCOL_DATA_DESCRIPTOR, ProtocolSpecificData);
const PROTOCOL_BYTES: usize = size_of::<STORAGE_PROTOCOL_SPECIFIC_DATA>();

pub(crate) fn disks() -> io::Result<Vec<Value>> {
    let mut names = vec![0u16; 65_536];
    // A null name requests the local DOS device namespace.
    let length = unsafe { QueryDosDeviceW(null(), names.as_mut_ptr(), names.len() as u32) };
    if length == 0 {
        return Err(io::Error::last_os_error());
    }
    let mut numbers: Vec<u32> = names[..length as usize]
        .split(|value| *value == 0)
        .filter_map(|name| {
            String::from_utf16_lossy(name)
                .strip_prefix("PhysicalDrive")?
                .parse()
                .ok()
        })
        .collect();
    numbers.sort_unstable();
    numbers.dedup();
    Ok(numbers.into_iter().filter_map(read_disk).collect())
}

fn open_disk(number: u32) -> io::Result<File> {
    let path: Vec<_> = format!(r"\\.\PhysicalDrive{number}")
        .encode_utf16()
        .chain([0])
        .collect();
    // Opening with zero desired access allows metadata queries without raw-sector access.
    let handle = unsafe {
        CreateFileW(
            path.as_ptr(),
            0,
            FILE_SHARE_READ | FILE_SHARE_WRITE,
            null(),
            OPEN_EXISTING,
            0,
            null_mut(),
        )
    };
    if handle == INVALID_HANDLE_VALUE {
        return Err(io::Error::last_os_error());
    }
    // Transfer this handle's ownership to File.
    Ok(unsafe { File::from_raw_handle(handle) })
}

fn control(device: &File, code: u32, input: &[u8], capacity: usize) -> io::Result<Vec<u8>> {
    let mut output = vec![0; capacity];
    let mut size = 0;
    let input_ptr = if input.is_empty() {
        null()
    } else {
        input.as_ptr().cast()
    };
    // The device is synchronous and both buffers stay alive for this read-only request.
    let okay = unsafe {
        DeviceIoControl(
            device.as_raw_handle(),
            code,
            input_ptr,
            input.len() as u32,
            output.as_mut_ptr().cast(),
            output.len() as u32,
            &mut size,
            null_mut(),
        )
    };
    if okay == 0 {
        return Err(io::Error::last_os_error());
    }
    output.truncate(size as usize);
    Ok(output)
}

fn bytes<const N: usize>(data: &[u8], offset: usize) -> Option<[u8; N]> {
    data.get(offset..offset.checked_add(N)?)?.try_into().ok()
}

fn u32_at(data: &[u8], offset: usize) -> Option<u32> {
    bytes(data, offset).map(u32::from_le_bytes)
}

fn property(device: &File, id: i32, capacity: usize) -> Option<Vec<u8>> {
    let mut request = [0; size_of::<STORAGE_PROPERTY_QUERY>()];
    request[..4].copy_from_slice(&id.to_le_bytes());
    control(device, IOCTL_STORAGE_QUERY_PROPERTY, &request, capacity).ok()
}

fn descriptor_text(data: &[u8], field: usize) -> Option<String> {
    let offset = u32_at(data, field)? as usize;
    if offset < offset_of!(STORAGE_DEVICE_DESCRIPTOR, RawDeviceProperties) {
        return None;
    }
    let remaining = data.get(offset..)?;
    let end = remaining.iter().position(|&byte| byte == 0)?;
    let value = String::from_utf8_lossy(&remaining[..end]).trim().to_owned();
    (!value.is_empty()).then_some(value)
}

fn read_disk(number: u32) -> Option<Value> {
    let name = format!("PhysicalDrive{number}");
    let device = match open_disk(number) {
        Ok(device) => device,
        Err(error) => {
            return Some(json!({ "number": number, "model": name, "error": error.to_string() }));
        }
    };
    let descriptor = property(&device, StorageDeviceProperty, 4096).unwrap_or_default();
    let bus = u32_at(&descriptor, offset_of!(STORAGE_DEVICE_DESCRIPTOR, BusType))
        .unwrap_or_default() as i32;
    if [BusTypeVirtual, BusTypeFileBackedVirtual, BusTypeSpaces].contains(&bus) {
        return None;
    }
    let model = descriptor_text(
        &descriptor,
        offset_of!(STORAGE_DEVICE_DESCRIPTOR, ProductIdOffset),
    )
    .or_else(|| {
        descriptor_text(
            &descriptor,
            offset_of!(STORAGE_DEVICE_DESCRIPTOR, VendorIdOffset),
        )
    })
    .unwrap_or(name);
    let firmware = descriptor_text(
        &descriptor,
        offset_of!(STORAGE_DEVICE_DESCRIPTOR, ProductRevisionOffset),
    );
    let size = control(&device, IOCTL_DISK_GET_DRIVE_GEOMETRY_EX, &[], 1024)
        .ok()
        .and_then(|data| bytes(&data, offset_of!(DISK_GEOMETRY_EX, DiskSize)))
        .map(i64::from_le_bytes)
        .filter(|&size| size >= 0)
        .map(|size| size.to_string());
    let (bus_name, mut smart) = if bus == BusTypeNvme {
        ("NVMe", nvme_health(&device).unwrap_or_else(|| json!({})))
    } else {
        let prediction = control(
            &device,
            IOCTL_STORAGE_PREDICT_FAILURE,
            &[],
            size_of::<STORAGE_PREDICT_FAILURE>(),
        )
        .ok()
        .and_then(|data| u32_at(&data, 0));
        let bus_name = [
            (BusTypeAta, "ATA"),
            (BusTypeSata, "SATA"),
            (BusTypeUsb, "USB"),
            (BusTypeScsi, "SCSI"),
            (BusTypeSas, "SAS"),
            (BusTypeRAID, "RAID"),
        ]
        .into_iter()
        .find_map(|(code, name)| (code == bus).then_some(name))
        .unwrap_or("");
        (
            bus_name,
            json!({ "warning": prediction.map(|value| value != 0) }),
        )
    };
    if smart["temperature"].is_null() {
        smart["temperature"] = json!(device_temperature(&device));
    }
    Some(json!({
        "number": number, "model": model, "firmware": firmware,
        "bus": bus_name, "size": size, "metrics": smart,
    }))
}

fn device_temperature(device: &File) -> Option<i16> {
    let data = property(device, StorageDeviceTemperatureProperty, 4096)?;
    let count = u16::from_le_bytes(bytes(
        &data,
        offset_of!(STORAGE_TEMPERATURE_DATA_DESCRIPTOR, InfoCount),
    )?);
    let sensors = data.get(offset_of!(STORAGE_TEMPERATURE_DATA_DESCRIPTOR, TemperatureInfo)..)?;
    sensors
        .as_chunks::<{ size_of::<STORAGE_TEMPERATURE_INFO>() }>()
        .0
        .iter()
        .take(count.into())
        .filter_map(|sensor| {
            bytes(sensor, offset_of!(STORAGE_TEMPERATURE_INFO, Temperature)).map(i16::from_le_bytes)
        })
        .find(|&temperature| temperature != i16::MIN)
}

fn nvme_health(device: &File) -> Option<Value> {
    let mut request = vec![0; QUERY_HEADER + PROTOCOL_BYTES + LOG_BYTES];
    request[..4].copy_from_slice(&StorageDeviceProtocolSpecificProperty.to_le_bytes());
    for (field, value) in [
        (
            offset_of!(STORAGE_PROTOCOL_SPECIFIC_DATA, ProtocolType),
            ProtocolTypeNvme as u32,
        ),
        (
            offset_of!(STORAGE_PROTOCOL_SPECIFIC_DATA, DataType),
            NVMeDataTypeLogPage as u32,
        ),
        (
            offset_of!(STORAGE_PROTOCOL_SPECIFIC_DATA, ProtocolDataRequestValue),
            NVME_LOG_PAGE_HEALTH_INFO as u32,
        ),
        (
            offset_of!(STORAGE_PROTOCOL_SPECIFIC_DATA, ProtocolDataOffset),
            PROTOCOL_BYTES as u32,
        ),
        (
            offset_of!(STORAGE_PROTOCOL_SPECIFIC_DATA, ProtocolDataLength),
            LOG_BYTES as u32,
        ),
    ] {
        request[QUERY_HEADER + field..QUERY_HEADER + field + 4]
            .copy_from_slice(&value.to_le_bytes());
    }
    let data = control(
        device,
        IOCTL_STORAGE_QUERY_PROPERTY,
        &request,
        request.len(),
    )
    .ok()?;
    let protocol = data.get(PROTOCOL_OFFSET..)?;
    if u32_at(
        protocol,
        offset_of!(STORAGE_PROTOCOL_SPECIFIC_DATA, ProtocolType),
    )? != ProtocolTypeNvme as u32
        || u32_at(
            protocol,
            offset_of!(STORAGE_PROTOCOL_SPECIFIC_DATA, DataType),
        )? != NVMeDataTypeLogPage as u32
    {
        return None;
    }
    let offset = u32_at(
        protocol,
        offset_of!(STORAGE_PROTOCOL_SPECIFIC_DATA, ProtocolDataOffset),
    )? as usize;
    let length = u32_at(
        protocol,
        offset_of!(STORAGE_PROTOCOL_SPECIFIC_DATA, ProtocolDataLength),
    )? as usize;
    if offset < PROTOCOL_BYTES || length < LOG_BYTES {
        return None;
    }
    parse_health(protocol.get(offset..)?)
}

fn parse_health(log: &[u8]) -> Option<Value> {
    let log = log.get(..LOG_BYTES)?;
    // NVME_HEALTH_INFO_LOG uses little-endian 128-bit counters. A string
    // preserves their full width across the JSON boundary.
    let counter = |index| bytes(log, index).map(u128::from_le_bytes);
    let text = |index| counter(index).map(|value| value.to_string());
    let transferred = |index| {
        counter(index)
            .filter(|&value| value != 0)
            .and_then(|value| value.checked_mul(512_000))
            .map(|value| value.to_string())
    };
    let kelvin = u16::from_le_bytes([log[1], log[2]]);
    Some(json!({
        "warning": log[0] != 0,
        "warningBits": log[0],
        "temperature": (kelvin != 0).then_some(i32::from(kelvin) - 273),
        "spare": log[3],
        "spareThreshold": log[4],
        "wear": log[5],
        "readBytes": transferred(32),
        "writtenBytes": transferred(48),
        "powerCycles": text(112),
        "powerOnHours": text(128),
        "unsafeShutdowns": text(144),
        "mediaErrors": text(160),
        "errorLogEntries": text(176),
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nvme_fields_preserve_zero_and_wide_counters() {
        let mut log = [0u8; LOG_BYTES];
        log[0] = 2;
        log[1..3].copy_from_slice(&300u16.to_le_bytes());
        log[5] = 12;
        log[32..48].copy_from_slice(&2u128.to_le_bytes());
        log[128..144].copy_from_slice(&((1u128 << 64) + 3).to_le_bytes());
        let health = parse_health(&log).unwrap();
        assert_eq!(health["temperature"], 27);
        assert_eq!(health["wear"], 12);
        assert_eq!(health["warning"], true);
        assert_eq!(health["readBytes"], "1024000");
        assert!(health["writtenBytes"].is_null());
        assert_eq!(health["powerOnHours"], "18446744073709551619");
        assert_eq!(health["mediaErrors"], "0");
        assert!(parse_health(&log[..LOG_BYTES - 1]).is_none());
    }
}
