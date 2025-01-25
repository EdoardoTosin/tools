# Automation Tools

## :sparkles: Introduction

This repository contains a collection of scripts designed to be executed directly from the command line through URLs. Each script is hosted online and can be invoked remotely, streamlining workflows and automating tasks across various platforms.

## :notebook: Script Catalog

For a comprehensive list of scripts available in this repository and their usage instructions, please refer to the [SCRIPT_CATALOG.md](SCRIPT_CATALOG.md) file. It contains a variety of scripts for different platforms like Python, Linux, and Windows, along with convenient one-liner commands for downloading and executing them. Feel free to explore and utilize these scripts to streamline your workflow and automate various tasks.

## :warning: Security Note

***Executing scripts directly from URLs can pose security risks if the script content is not trusted. Always verify the source of the script and consider the potential implications of running remote scripts.***

## :clipboard: How to Use in Linux

To execute a script in Linux, use the following command format:

```sh
curl https://raw.githubusercontent.com/EdoardoTosin/tools/main/_script/script-name.sh | sh
```

```sh
curl https://raw.githubusercontent.com/EdoardoTosin/tools/main/_script/script-name.py | python
```

*Replace `script-name` with the actual filename of the script you wish to run.*

### Passing Arguments

Some scripts may require arguments. To pass arguments, append them after the script URL:

```sh
curl https://raw.githubusercontent.com/EdoardoTosin/tools/main/_script/script-name.sh | sh -s -- arg1 arg2
```

Replace `arg1 arg2` with the actual arguments expected by the script.

## :clipboard: How to Use in Windows

To execute a script in Windows, use the following command format:

```powershell
irm "https://raw.githubusercontent.com/EdoardoTosin/tools/main/_script/script-name.ps1" | iex
```

```powershell
irm "https://raw.githubusercontent.com/EdoardoTosin/tools/main/_script/script-name.py" | python
```

*Replace `script-name` with the actual filename of the script you wish to run.*

## :busts_in_silhouette: Contributing

Contributions to the development of new scripts or improvements to existing ones are welcome. Please follow the standard GitHub workflow for submitting contributions.

## :page_facing_up: License

All scripts in this repository are released under the MIT License. See the [LICENSE](LICENSE) file for details.
