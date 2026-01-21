# Version 2.0.0
Adds support for ubuntu on x86_64 architecture

| Area             | Raspberry Pi                    | Ubuntu Intel |
|------------------|----------------------------------|--------------|
| Swap             | zram + swap fully disabled       | swap only    |
| Boot config      | /boot/firmware/cmdline.txt       | No boot edits |
| Cgroups          | forced v2                        | verified v2  |
| containerd repo  | Debian                           | Ubuntu       |
| Architecture     | arm64                            | amd64        |
| kubeadm flags    | Pi workaround                    | clean init   |
| Safety checks    | enforced                         | enforced     |
