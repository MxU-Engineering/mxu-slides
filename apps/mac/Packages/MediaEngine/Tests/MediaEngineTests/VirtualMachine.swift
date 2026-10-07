import Foundation

func isVirtualMachine() -> Bool {
    var present: Int32 = 0
    var size = MemoryLayout<Int32>.size
    let read = sysctlbyname("kern.hv_vmm_present", &present, &size, nil, 0)
    return read == 0 && present != 0
}
