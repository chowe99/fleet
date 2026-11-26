# Test fixture (MAY be edited to make the VM mechanics work; never to weaken what it reports).
# boot_until_good(machine, max_starts): start the VM; a boot counts as good only when boot-complete.target
# is reached. If the VM instead powers itself off or reboots (QEMU in NixOS tests exits on a guest
# reboot), start it again. Returns how many starts it took. Every start must be a real boot of the VM.
import time


def boot_until_good(machine, max_starts, per_boot_timeout=900):
    for n in range(1, max_starts + 1):
        machine.start()
        deadline = time.time() + per_boot_timeout
        while time.time() < deadline:
            if machine.process is not None and machine.process.poll() is not None:
                break  # the guest rebooted or powered off: QEMU exited
            try:
                status, _ = machine.execute("systemctl is-active --quiet boot-complete.target", timeout=10)
                if status == 0:
                    return n
            except Exception:
                pass  # shell not connected yet, or the VM went away mid-command
            time.sleep(3)
        else:
            raise Exception(f"start {n}: neither a good boot nor a reboot within {per_boot_timeout}s")
        machine.wait_for_shutdown()
    raise Exception(f"no good boot in {max_starts} starts")
