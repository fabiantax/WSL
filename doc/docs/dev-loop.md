# Building WSL

## Prerequisites 

The following tools are required to build WSL: 

- CMake >= 3.25
    - Can be installed with `winget install Kitware.CMake`
- Visual Studio with the following components:
    - Windows SDK 26100
    - MSBuild
    - Universal Windows platform support for v143 build tools (X64 and ARM64)
    - MSVC v143 - VS 2022 C++ ARM64 build tools (Latest + Spectre) (X64 and ARM64)
    - C++ core features
    - C++ ATL for latest v143 tools (X64 and ARM64)
    - C++ Clang compiler for Windows
    - .NET desktop development
    - .NET WinUI app development tools

- Building WSL requires support for symbolic links. To ensure this capability, enable [Developer Mode](https://learn.microsoft.com/en-us/windows/apps/get-started/enable-your-device-for-development) in Windows Settings or execute the build process with Administrator privileges.
    
## Building WSL

Once you have cloned the repository, generate the Visual Studio solution by running:

```
cmake .
```

This will generate a `wsl.sln` file that you can build either with Visual Studio, or via `cmake --build .`.

Build parameters:

- `cmake . -A arm64`: Build a package for ARM64
- `cmake . -DCMAKE_BUILD_TYPE=Release`: Build for release
- `cmake . -DBUILD_BUNDLE=TRUE`: Build a bundle msix package (requires building ARM64 first)

Note: To build and deploy faster during development, see options in `UserConfig.cmake`.


## Deploying WSL 

Once the build is complete, you can install WSL by installing the MSI package found under `bin\<platform>\<target>\wsl.msi`, or by running `powershell tools\deploy\deploy-to-host.ps1`.

To deploy on a Hyper-V virtual machine, you can use `powershell tools\deploy\deploy-to-vm.ps1 -VmName <vm> -Username <username> -Password <password>`

## Running tests

To run unit tests, run: `bin\<platform>\<target>\test.bat`. There's quite a lot of tests so you probably don't want to run everything. Here's a reasonable subset:
`bin\<platform>\<target>\test.bat /name:*UnitTest*`

To run a specific test case run:
`bin\<platform>\<target>\test.bat /name:<class>::<test>`
Example: `bin\x64\debug\test.bat /name:UnitTests::UnitTests::ModernInstall` 

To run the tests for WSL1, add `-Version 1`. 
Example: `bin\x64\debug\test.bat -Version 1` 


After running the tests once, you can add `-f` to skip the package installation, which makes the tests faster (this requires test_distro to be the default WSL distribution).

Example:

```
wsl --set-default test_distro
bin\x64\debug\test.bat /name:*UnitTest* -f
```

## Building a Custom Kernel (AMD GPU + Docker)

WSL2 supports loading a custom kernel binary via the `kernel=` key in
`%USERPROFILE%\.wslconfig`.  The repository ships a config fragment and a
build script that add full **AMD GPU / ROCm** (`/dev/kfd`) and **Docker**
support on top of Microsoft's base WSL2 kernel config, with extra tuning for
**Zen 5 / Strix Halo** (AMD Ryzen AI 395 Pro / HX 395) hardware.

### What is included

| Category | Key flags |
|---|---|
| Docker (cgroups & networking) | `CONFIG_CGROUPS`, `CONFIG_MEMCG`, `CONFIG_BLK_CGROUP`, `CONFIG_CGROUP_SCHED`, `CONFIG_CGROUP_PIDS`, `CONFIG_NAMESPACES`, `CONFIG_NET_NS`, `CONFIG_NF_TABLES`, `CONFIG_NFT_NAT`, `CONFIG_NFT_MASQ`, `CONFIG_NETFILTER_XT_MATCH_CONNTRACK`, `CONFIG_IP_NF_IPTABLES`, `CONFIG_IP_NF_TARGET_MASQUERADE` |
| AMD GPU / ROCm | `CONFIG_DRM_AMDGPU`, `CONFIG_DRM_AMDGPU_USERPTR`, `CONFIG_HSA_AMD` (creates `/dev/kfd`), `CONFIG_DXGKRNL` (Windows↔Linux GPU bridge) |
| Zen 5 / Strix Halo | `CONFIG_MZEN5`, `CONFIG_NR_CPUS=32`, `CONFIG_NUMA` |

The full fragment lives at [`kernel/config-fragment-amd-docker`](../../kernel/config-fragment-amd-docker).

### Quick build

```bash
# 1. Clone the Microsoft kernel source (one-time)
git clone https://github.com/microsoft/WSL2-Linux-Kernel.git ~/WSL2-Linux-Kernel

# 2. Install build dependencies (Ubuntu/Debian)
sudo apt update && sudo apt install -y \
    build-essential flex bison libssl-dev libelf-dev bc pahole dwarves python3 cpio zstd

# 3. Run the build script
./tools/build-kernel.sh
```

The script follows the safe build workflow:

1. Starts from `Microsoft/config-wsl` (the same config Microsoft ships)
2. Merges `kernel/config-fragment-amd-docker` on top via `merge_config.sh`
3. Compiles with `make -j$(nproc)`
4. Outputs `~/wsl2-custom-kernel/bzImage`

Use `--kernel-src` and `--output` to override default paths, or `-j <N>` to
control parallelism.  Run `./tools/build-kernel.sh --help` for all options.

### Activating the kernel

Add the following to `%USERPROFILE%\.wslconfig` on Windows (the build script
prints the exact path after a successful build):

```ini
[wsl2]
kernel=C:\Users\<YourUsername>\wsl2-custom-kernel\bzImage
```

Then restart WSL:

```powershell
wsl --shutdown
wsl
```

Verify the kernel is loaded:

```bash
uname -r          # should end in -wsl2-amd-docker
ls /dev/kfd       # AMD GPU ROCm node — present when AMD GPU flags are active
docker info       # Docker daemon should start successfully
```

## Debugging tests

See [debugging](debugging.md) for general debugging instructions.

To attach a debugger to the unit test process, use: `/waitfordebugger` when calling `test.bat`. 
Use `/breakonfailure` to automatically break on the first test failure. 
