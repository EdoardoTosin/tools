# Automation Tools

## Introduction

This repository contains a collection of scripts designed to be executed directly from the command line through URLs. Each script is hosted online and can be invoked remotely, streamlining workflows and automating tasks across various platforms.

## How to Use

To execute a script hosted on this platform, use the following command format:

```bash
curl https://edoardotosin.com/automation/script-name.sh | bash
```

Replace `script-name.sh` with the actual name of the script you wish to run.

### Passing Arguments

Some scripts may require arguments. To pass arguments, append them after the script URL:

```bash
curl https://edoardotosin.com/automation/script-name.sh | bash -s -- arg1 arg2
```

Replace `arg1 arg2` with the actual arguments expected by the script.

## List of Scripts

**[Caddy Installer Automation](scripts/prepare-caddy.sh)**

```bash
curl https://edoardotosin.com/automation/prepare-caddy.sh | bash
```

## Security Note

Executing scripts directly from URLs can pose security risks if the script content is not trusted. Always verify the source of the script and consider the potential implications of running remote scripts.

## Contributing

Contributions to the development of new scripts or improvements to existing ones are welcome. Please follow the standard GitHub workflow for submitting contributions.

## License

All scripts in this repository are released under the MIT License. See the [LICENSE](LICENSE) file for details.
