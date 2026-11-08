# Hotspot over TUN

[中文使用说明](使用说明.md)

Route Windows 11 Mobile Hotspot traffic through FlClash TUN. Phones and tablets use the hotspot as their gateway and need no proxy setup.

```text
Connected device → Windows Mobile Hotspot → FlClash TUN → FlClash routing rules
```

## Requirements

- Windows 11 with a working Mobile Hotspot and Windows PowerShell 5.1.
- Administrator access for starting, stopping, or restoring the hotspot.
- FlClash running with TUN enabled and working internet access. The script looks for the `FlClash` connection profile and a network adapter named `FlClash` or described as `Meta Tunnel`.

## Quick start

1. Clone this repository or download it as a ZIP and extract it to a writable folder. If needed, set the hotspot name and password in Windows Settings before using the scripts.
2. Enable FlClash TUN and close Windows Settings. Run `Start-Hotspot.cmd` and accept the UAC prompt.
3. Connect your device to the hotspot you configured in Windows. Run `Status-Hotspot.cmd` to check that the hotspot is on (`热点状态: On`), TUN is the upstream (`TUN 上游: 是`), and the gateway is `192.168.137.1`.
4. Run `Stop-Hotspot.cmd` to turn off the hotspot and write back the saved preferred upstream when available. Use `Restore-Hotspot.cmd` in place of Stop if you want to bring back a hotspot that was already on before Start. Turn off FlClash TUN before reopening the original hotspot with Restore.

Use the scripts to control the hotspot during a session. Toggling it in Windows Settings can switch the upstream back to Wi-Fi.

## How it works

The PowerShell script saves the current hotspot state, sets the Internet Connection Sharing (ICS) preferred upstream to the FlClash TUN adapter, then starts Mobile Hotspot through Windows WinRT. It checks that the hotspot gateway appears and the preferred upstream still points to TUN.

The optional `7890` listener check is useful for the manual proxy fallback described in the [Chinese guide](使用说明.md). Runtime logs and the state snapshot are stored next to the script.

## License

[MIT](LICENSE)
