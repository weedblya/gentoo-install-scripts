# Gentoo Install Scripts -- BETA!!!

Автоматизированная установка Gentoo AMD64 из Gentoo Live ISO.

> ⚠️ **ВНИМАНИЕ:** установщик умеет полностью стирать выбранный диск. Перед запуском внимательно проверьте `lsblk` и выбранный диск.

## Что устанавливается

Есть два этапа:

- `install_part1.sh` — выполняется в Gentoo Live ISO **до chroot**.
- `install_part2.sh` — выполняется вручную **внутри chroot**.

Профили:

- `gentoo_base` — базовая desktop-ready система без привязки к WM/DE; X11/Wayland и XWayland.
- `gentoo_niri` — база + Niri, Waybar, fuzzel, mako, swaybg, swayidle, swaylock и Ly.
- `gentoo_hyprland` — база + Hyprland, Waybar, portal Hyprland, hyprlock, hypridle, hyprpaper, hyprpicker и Ly.

Init:

- systemd
- OpenRC

Ядро:

- используется **`sys-kernel/gentoo-kernel`**;
- **`gentoo-kernel-bin` не используется**;
- ядро собирается локально на устанавливаемой машине;
- `MAKEOPTS` рассчитывается автоматически по CPU/RAM.

NVIDIA:

- устанавливается `x11-drivers/nvidia-drivers`;
- X11/Wayland поддержка включается через Portage USE.

## Разметка

Автоматический режим:

- GPT / UEFI
- EFI: 1 GiB FAT32
- swap: размер выбирается перед автоматической разметкой (например `8G`, `16G` или `NONE`)
- root: всё оставшееся место, ext4

Также доступны:

- cfdisk
- fdisk
- parted

При ручной разметке EFI/root/swap указываются пользователем. Swap можно отключить, введя `NONE`.

## Запуск

Загрузитесь с Gentoo Live ISO в **UEFI** и получите root shell.

Если репозиторий уже доступен через GitHub:

```bash
git clone https://github.com/weedblya/gentoo-install-scripts.git /root/gentoo-installer
cd /root/gentoo-installer
chmod +x install_part1.sh install_part2.sh
./install_part1.sh
```

Скрипт попросит выбрать:

1. диск;
2. профиль;
3. init;
4. способ разметки;
5. размер swap при автоматической разметке.

Например, для автоматической разметки можно указать:

```
16G
```

или:

```
8G
```

Если swap не нужен, можно указать `NONE`.

В ручном режиме размер swap задаётся самой разметкой диска: установщик только попросит выбрать созданный swap-раздел или `NONE`.

После завершения первой части **chroot выполняется вручную**:

```bash
mount --types proc /proc /mnt/gentoo/proc
mount --rbind /sys /mnt/gentoo/sys
mount --make-rslave /mnt/gentoo/sys
mount --rbind /dev /mnt/gentoo/dev
mount --make-rslave /mnt/gentoo/dev
mount --rbind /run /mnt/gentoo/run
mount --make-rslave /mnt/gentoo/run
cp --dereference /etc/resolv.conf /mnt/gentoo/etc/resolv.conf
chroot /mnt/gentoo /bin/bash
source /etc/profile
/root/install_part2.sh
```

После завершения второй части:

```bash
exit
umount -R /mnt/gentoo
reboot
```

## Пользователь

Во второй части установщик запросит:

- hostname системы;
- пароль root;
- имя нового пользователя;
- пароль пользователя.

Пользователь получает группы:

- wheel
- video
- audio
- render
- input
- seat (если такая группа существует)

Для `wheel` создаётся sudoers-правило.

## Portage

Установщик использует:

- `--autounmask=y`
- `--autounmask-write=y`
- `--autounmask-unrestricted-atoms=y`
- `--backtrack=30`
- `--getbinpkg`

Настройки создаются в:

- `/etc/portage/package.use/`
- `/etc/portage/package.accept_keywords/`
- `/etc/portage/package.unmask/`
- `/etc/portage/package.mask/`

При необходимости Portage-конфигурация применяется через `etc-update`.

**Глобальный `~amd64` включается.**

Это сделано специально для режима установки, похожего на Arch:
пользователь может устанавливать больше пакетов без ручного добавления
`package.accept_keywords`.

Такой режим более агрессивный и может привести к использованию
нестабильных версий пакетов.

## Репозитории

Используются:

- Gentoo main repository;
- GURU;
- Hyprland profile дополнительно включает hyproverlay.

## Stage 3

Первая часть автоматически определяет актуальный Stage 3 для выбранного init, скачивает его с Gentoo distfiles и проверяет SHA256 перед распаковкой.

## Логи

Логи сохраняются:

- в Live ISO: `/tmp/gentoo-install-part1-*.log`;
- в установленной системе: `/root/gentoo-install-part1.log`;
- в установленной системе после второй части: `/root/gentoo-install-part2-*.log` и `/root/gentoo-install-part2-final.log`.

## Важно

Это автоматизатор установки, а не LiveCD сам по себе. После неудачного запуска первую часть можно запустить повторно: скрипт перед новой разметкой пытается отключить старый swap и размонтировать разделы выбранного диска, затем заново перечитывает таблицу разделов.

Перед использованием на единственном рабочем диске рекомендуется сначала проверить его в виртуальной машине или на отдельном физическом диске.

Скрипты рассчитаны на **AMD64 + UEFI**.

