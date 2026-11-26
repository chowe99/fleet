# Test fixture (MAY be edited to make the VM mechanics work; never to weaken what it checks or reports).
# Builds the disks a PC is made of on the test host and the QEMU command lines that boot them.
# The test sets OVMF_CODE, OVMF_VARS and puts the tools on PATH before including this file.
import hashlib
import json
import os
import shlex
import shutil
import subprocess
import tempfile
import time

WORK = os.path.join(os.getcwd(), "installer-test")
os.makedirs(WORK, exist_ok=True)

ESP_TYPE = "C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
MSDATA_TYPE = "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7"  # Microsoft basic data (Windows' C: drive)

# A PC with a TPM has firmware that knows it. nixpkgs' default OVMF (OVMF_CODE above) is built without TPM
# support, so systemd-boot tells the OS the firmware has no TPM (LoaderTpm2ActivePcrBanks=0) and
# `systemd-analyze has-tpm2` reports only partial support: the encryption module then rightly refuses to
# depend on the TPM and never finishes first boot. QEMU's own EDK2 build of the same OVMF, next to the
# qemu-system-x86_64 on PATH, is built with TPM2 support; every PC here uses it, code and NVRAM alike.
_QEMU_SHARE = os.path.join(os.path.dirname(os.path.realpath(shutil.which("qemu-system-x86_64"))), "..", "share", "qemu")
PC_CODE = os.path.join(_QEMU_SHARE, "edk2-x86_64-code.fd")
PC_VARS = os.path.join(_QEMU_SHARE, "edk2-i386-vars.fd")


def run(*cmd, input=None):
    r = subprocess.run(cmd, input=input, capture_output=True, text=True)
    if r.returncode != 0:
        raise Exception(f"{' '.join(cmd)} failed ({r.returncode}): {r.stderr}")
    return r.stdout


def partitions(image):
    """[(start_byte, size_bytes, type_guid), ...] from the image's GPT."""
    table = json.loads(run("sfdisk", "--json", image))["partitiontable"]
    ss = table.get("sectorsize", 512)
    return [(p["start"] * ss, p["size"] * ss, p["type"].upper()) for p in table.get("partitions", [])]


def esp_offset(image):
    for start, _, ptype in partitions(image):
        if ptype == ESP_TYPE:
            return start
    raise Exception(f"{image} has no EFI system partition")


def fat_put(target, name, data):
    """Write `data` to `name` (e.g. "fleet/install.json") on a FAT file system; `target` is "file" or "file@@offset"."""
    parts = name.split("/")
    for i in range(1, len(parts)):
        subprocess.run(["mmd", "-D", "s", "-i", target, "::" + "/".join(parts[:i])], capture_output=True)
    src = os.path.join(WORK, "put.tmp")
    with open(src, "wb") as f:
        f.write(data)
    run("mcopy", "-o", "-i", target, src, "::" + name)
    os.remove(src)


def fat_delete(target, name):
    subprocess.run(["mdel", "-i", target, "::" + name], capture_output=True)


def windows_disk(path, size="16G", config=None):
    """A Windows PC's disk: GPT, an EFI system partition with Windows' boot manager (and fleet/install.json when
    `config` is given, as the migration script stages it), and a data partition holding a user's file."""
    if os.path.exists(path):
        os.remove(path)
    run("truncate", "-s", size, path)
    run("sfdisk", "-q", path, input=f"label: gpt\n,260M,{ESP_TYPE}\n,2G,{MSDATA_TYPE}\n")
    (esp_off, esp_size, _), (data_off, data_size, _) = partitions(path)
    esp = os.path.join(WORK, "esp.img")
    data = os.path.join(WORK, "data.img")
    for f in (esp, data):
        if os.path.exists(f):
            os.remove(f)
    run("truncate", "-s", str(esp_size), esp)
    run("mkfs.vfat", "-F", "32", "-n", "SYSTEM", esp)
    fat_put(esp, "EFI/Microsoft/Boot/bootmgfw.efi", b"Windows Boot Manager stand-in\n")
    if config is not None:
        fat_put(esp, "fleet/install.json", json.dumps(config).encode())
    tree = os.path.join(WORK, "c-drive")
    shutil.rmtree(tree, ignore_errors=True)
    os.makedirs(os.path.join(tree, "Users/alice/Documents"))
    with open(os.path.join(tree, "Users/alice/Documents/report.txt"), "w") as f:
        f.write("alice's quarterly report\n")
    run("truncate", "-s", str(data_size), data)
    run("mkfs.ext4", "-q", "-L", "Windows", "-d", tree, data)  # stands in for NTFS; the installer must not care
    for img, off in ((esp, esp_off), (data, data_off)):
        run("dd", f"if={img}", f"of={path}", "bs=1M", f"seek={off // 2**20}", "conv=notrunc,sparse", "status=none")
        os.remove(img)
    return path


def blank_disk(path, size="16G"):
    if os.path.exists(path):
        os.remove(path)
    run("truncate", "-s", size, path)
    return path


def installer_stick(src_image, path, config=None):
    """A USB stick written from the installer image, with fleet/install.json dropped onto its FAT partition
    (what a technician does after writing the image), or without one."""
    if not os.path.exists(path):
        run("cp", "--sparse=always", src_image, path)
        os.chmod(path, 0o644)
    target = f"{path}@@{esp_offset(path)}"
    fat_delete(target, "fleet/install.json")
    if config is not None:
        fat_put(target, "fleet/install.json", json.dumps(config).encode())
    return path


def digest(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(2**22), b""):
            h.update(chunk)
    return h.hexdigest()


def recovery_opens(image, key):
    """Whether `key` unlocks the LUKS2 volume on any partition of `image` (checked against a copy of its header)."""
    for i, (start, size, _) in enumerate(partitions(image)):
        with open(image, "rb") as f:
            f.seek(start)
            if f.read(6) != b"LUKS\xba\xbe":
                continue
        hdr = os.path.join(WORK, f"luks-header-{i}.img")
        run("dd", f"if={image}", f"of={hdr}", "bs=1M", f"skip={start // 2**20}", f"count={min(64, size // 2**20)}", "status=none")
        r = subprocess.run(["cryptsetup", "open", "--test-passphrase", "--key-file=-", hdr], input=key.encode(), capture_output=True)
        os.remove(hdr)
        if r.returncode == 0:
            return True
    return False


def start_swtpm(name):
    # The TPM's state lives with the PC; its socket goes in a short path (unix sockets allow ~107 bytes).
    d = os.path.join(WORK, f"{name}-tpm")
    os.makedirs(d, exist_ok=True)
    sock = os.path.join(tempfile.mkdtemp(prefix="tpm"), "sock")
    if os.path.exists(sock):
        os.remove(sock)
    proc = subprocess.Popen(["swtpm", "socket", "--tpmstate", f"dir={d}", "--ctrl", f"type=unixio,path={sock}",
                             "--tpm2", "--flags", "startup-clear"])
    for _ in range(100):
        if os.path.exists(sock):
            break
        time.sleep(0.1)
    return proc, sock


def pc_command(name, internal=(), usb=(), tpm_sock=None, serial="FLEET-SN-0001"):
    """QEMU for one UEFI PC: USB sticks boot first (a technician picked the stick in the boot menu), then the
    internal NVMe disks. The firmware's NVRAM (boot entries) belongs to the PC and persists between starts.
    The test driver appends -serial stdio and -no-reboot, so a restart or power-off ends the QEMU process."""
    nvram = os.path.join(WORK, f"{name}-vars.fd")
    if not os.path.exists(nvram):
        shutil.copy(PC_VARS, nvram)
        os.chmod(nvram, 0o644)
    args = [
        "qemu-system-x86_64", "-enable-kvm", "-machine", "q35", "-cpu", "max", "-m", "3072", "-smp", "2",
        "-drive", f"if=pflash,format=raw,readonly=on,file={PC_CODE}",
        "-drive", f"if=pflash,format=raw,file={nvram}",
        "-smbios", f"type=1,manufacturer=Fakeco,product=Example Desk,serial={serial}",
        "-nic", "user,model=virtio-net-pci",
        "-device", "qemu-xhci,id=xhci",
    ]
    boot = 0
    for i, disk in enumerate(usb):
        args += ["-drive", f"if=none,id=usb{i},format=raw,file={disk}",
                 "-device", f"usb-storage,bus=xhci.0,drive=usb{i},removable=on,bootindex={boot}"]
        boot += 1
    for i, disk in enumerate(internal):
        args += ["-drive", f"if=none,id=nvme{i},format=raw,file={disk}",
                 "-device", f"nvme,drive=nvme{i},serial=NVME{i:04d},bootindex={boot}"]
        boot += 1
    if tpm_sock:
        args += ["-chardev", f"socket,id=chrtpm,path={tpm_sock}", "-tpmdev", "emulator,id=tpm0,chardev=chrtpm",
                 "-device", "tpm-tis,tpmdev=tpm0"]
    return " ".join(shlex.quote(a) for a in args)


def wait_gone(machine, timeout):
    """Wait until the VM restarts or powers off by itself (QEMU exits); fail after `timeout` seconds."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        if machine.process is not None and machine.process.poll() is not None:
            machine.wait_for_shutdown()
            return
        time.sleep(2)
    raise Exception(f"{machine.name} still running after {timeout}s")


def kill(machine):
    if machine.process is not None and machine.process.poll() is None:
        machine.process.kill()
    machine.wait_for_shutdown()
