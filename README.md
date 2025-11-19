# Automation Tools

A collection of automation scripts for Python, PowerShell, and Bash. Includes utilities for Raspberry Pi devices.

## Documentation

See [SCRIPT_CATALOG.md](SCRIPT_CATALOG.md) for a complete list of available scripts and usage instructions.

## Usage

### Linux

Execute shell scripts:

```sh
curl https://raw.githubusercontent.com/EdoardoTosin/tools/main/_script/script-name.sh | sh
```

Execute Python scripts:

```sh
curl https://raw.githubusercontent.com/EdoardoTosin/tools/main/_script/script-name.py | python
```

Pass arguments to scripts:

```sh
curl https://raw.githubusercontent.com/EdoardoTosin/tools/main/_script/script-name.sh | sh -s -- arg1 arg2
```

### Windows

Execute PowerShell scripts:

```powershell
irm "https://raw.githubusercontent.com/EdoardoTosin/tools/main/_script/script-name.ps1" | iex
```

Execute Python scripts:

```powershell
irm "https://raw.githubusercontent.com/EdoardoTosin/tools/main/_script/script-name.py" | python
```

## Security

**Warning:** Executing scripts directly from remote URLs is potentially dangerous. Always review script contents before execution and verify the source is trusted.

## Contributing

Contributions are welcome. Follow standard GitHub workflow for pull requests.

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for more details.
