import Darwin
import Metal

enum PerformanceMemory {
    static func processFootprintBytes() -> UInt64? {
        processFootprintBytes { info, count in
            withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
        }
    }

    static func processFootprintBytes(
        query: (inout task_vm_info_data_t, inout mach_msg_type_number_t) -> kern_return_t
    ) -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = query(&info, &count)
        // The TASK_VM_INFO revision 0 prefix ends immediately before phys_footprint.
        guard result == KERN_SUCCESS,
            let offset = MemoryLayout<task_vm_info_data_t>.offset(of: \.phys_footprint),
            Int(count) * MemoryLayout<integer_t>.size >= offset + MemoryLayout<UInt64>.size
        else { return nil }
        return info.phys_footprint
    }

    struct DeviceAllocation: Equatable {
        let registryID: UInt64
        let bytes: UInt64
    }

    static func metalAllocation(for device: MTLDevice?) -> DeviceAllocation? {
        device.flatMap {
            metalAllocation(registryID: $0.registryID, bytes: $0.currentAllocatedSize)
        }
    }

    static func metalAllocation(registryID: UInt64, bytes: Int) -> DeviceAllocation? {
        UInt64(exactly: bytes).map { DeviceAllocation(registryID: registryID, bytes: $0) }
    }
}
