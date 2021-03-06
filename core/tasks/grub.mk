# cleanup targets
CLEAN_TARGETS += grub_clean
DISTCLEAN_TARGETS += grub_distclean

# paths
GRUB_DIR = $(TOPDIR)grub
GRUB_OUT = $(TARGET_COMMON_OUT)/grub
GRUB_TARGET_OUT = $(TARGET_OUT)/grub
GRUB_BOOT_FS_DIR = $(GRUB_TARGET_OUT)/grub_rootfs

# default variables
GRUB_FONT_SIZE ?= 16
GRUB_COMPRESSION ?= cat
GRUB_BOOT_PATH_PREFIX ?= boot/

# files
FILE_GRUB_KERNEL = $(GRUB_TARGET_OUT)/grub_core.img
FILE_GRUB_FILEIMAGE = $(GRUB_TARGET_OUT)/grub_fileimage.img
FILE_GRUB_CONFIG = $(CONFIG_DIR)/load.cfg

# builtin modules
GRUB_BUILTIN_MODULES = $(shell cat $(CONFIG_DIR)/modules_builtin.lst | grep -v "^\s*\#" | xargs -I{} sh -c "echo {} | cut -d\# -f1" | xargs)
ifneq ($(wildcard build/devices/$(DEVICE_NAME)/modules_builtin.lst),)
GRUB_BUILTIN_MODULES += $(shell cat build/devices/$(DEVICE_NAME)/modules_builtin.lst | grep -v "^\s*\#" | xargs -I{} sh -c "echo {} | cut -d\# -f1" | xargs)
endif

# grub/grub2
ifneq (, $(shell which grub2-mkfont))
GRUB_TOOL_PREFIX=grub2
else ifneq (, $(shell which grub-mkfont))
GRUB_TOOL_PREFIX=grub
else
$(error "Couldn't find grub(2) tools")
endif

# device specific grub.cfg
GRUB_DEVICE_GRUB_CFG = build/devices/$(DEVICE_NAME)/grub.cfg

# create out directories
$(shell mkdir -p $(GRUB_OUT))
$(shell mkdir -p $(GRUB_TARGET_OUT))

# generate Makefiles
grub_configure: $(GRUB_OUT)/Makefile
.PHONY : grub_configure
$(GRUB_OUT)/Makefile:
	@ cd $(GRUB_DIR) && \
	./autogen.sh && \
	cd $(PWD)/$(GRUB_OUT) && \
	$(PWD)/$(GRUB_DIR)/configure --with-platform=efi --host $(TOOLCHAIN_LINUX_GNUEABIHF_HOST) CFLAGS='-static-libgcc -Wl,-static'

# main kernel
grub_core: grub_configure
	$(MAKE) -C $(GRUB_OUT)
.PHONY : grub_core

# u-boot image
grub_kernel: grub_core
	qemu-arm -r 3.11 -L $(TOOLCHAIN_LINUX_GNUEABIHF_LIBC) \
		$(GRUB_OUT)/grub-mkimage -c $(FILE_GRUB_CONFIG) -O arm-efi -o $(FILE_GRUB_KERNEL) \
			-d $(GRUB_OUT)/grub-core -p "" $(GRUB_BUILTIN_MODULES)
.PHONY : grub_kernel

# boot image
grub_boot_fs: grub_kernel multiboot
	# cleanup
	rm -Rf $(GRUB_BOOT_FS_DIR)/*
	rm -f /tmp/grub_font.pf2
	
	# directories
	mkdir -p $(GRUB_BOOT_FS_DIR)/boot/grub
	mkdir -p $(GRUB_BOOT_FS_DIR)/boot/grub/fonts
	mkdir -p $(GRUB_BOOT_FS_DIR)/boot/grub/locale
	
	# font
	$(GRUB_TOOL_PREFIX)-mkfont -s $$(build/tools/font_inch_to_px $(DISPLAY_PPI) "0.11") -o $(GRUB_TARGET_OUT)/unifont_uncompressed.pf2 $(PREBUILTS_DIR)/unifont/unifont.ttf
	cat $(GRUB_TARGET_OUT)/unifont_uncompressed.pf2 | $(GRUB_COMPRESSION) > $(GRUB_BOOT_FS_DIR)/boot/grub/fonts/unicode.pf2
	# env
	$(GRUB_TOOL_PREFIX)-editenv $(GRUB_BOOT_FS_DIR)/boot/grub/grubenv create
	# config
	cp $(CONFIG_DIR)/grub.cfg $(GRUB_BOOT_FS_DIR)/boot/grub/
	sed -i -e '/{DEVICE_SPECIFIC_GRUB_CFG}/{r $(GRUB_DEVICE_GRUB_CFG)' -e 'd}' $(GRUB_BOOT_FS_DIR)/boot/grub/grub.cfg
	# kernel
	cp $(FILE_GRUB_KERNEL) $(GRUB_BOOT_FS_DIR)/boot/grub/core.img
	# modules
	mkdir $(GRUB_BOOT_FS_DIR)/boot/grub/arm-efi
	cp $(GRUB_OUT)/grub-core/*\.mod $(GRUB_BOOT_FS_DIR)/boot/grub/arm-efi/
	# multiboot
	cp -R $(MULTIBOOT_BOOTFS) $(GRUB_BOOT_FS_DIR)/boot/grub/multiboot
	# TWRP curtain
	mkdir $(GRUB_BOOT_FS_DIR)/boot/grub/multiboot/res/
	convert $(PREBUILTS_DIR)/logo/g4a.png \
		-resize $$(build/tools/font_inch_to_px $(DISPLAY_PPI) "0.8")x$$(build/tools/font_inch_to_px $(DISPLAY_PPI) "0.8") \
		-gravity center -background black -extent $(DISPLAY_WIDTH)x$(DISPLAY_HEIGHT) \
		-pointsize $$(build/tools/font_inch_to_px $(DISPLAY_PPI) "0.19") \
		-fill white -draw "text 0,-$$(($$(build/tools/font_inch_to_px $(DISPLAY_PPI) 0.8)/2+$$(build/tools/font_inch_to_px $(DISPLAY_PPI) 0.19))) 'TWRP'" \
		-fill white -draw "text 0,$$(($$(build/tools/font_inch_to_px $(DISPLAY_PPI) 0.8)/2+$$(build/tools/font_inch_to_px $(DISPLAY_PPI) 0.19))) 'Multiboot'" \
		$(GRUB_BOOT_FS_DIR)/boot/grub/multiboot/res/twrp_curtain.jpg
.PHONY : grub_boot_fs

grub_sideload_image: grub_boot_fs mkbootimg
	# tar grub fs
	rm -f $(TARGET_OUT)/grub_fs.cpio
	cd $(GRUB_BOOT_FS_DIR) && \
		find . | cpio -o -H newc -R root:root > $(PWD)/$(TARGET_OUT)/grub_fs.cpio
	
	# build sideload image
	$(MKBOOTIMG) --kernel $(FILE_GRUB_KERNEL) --ramdisk $(TARGET_OUT)/grub_fs.cpio \
		--pagesize 2048 -o $(TARGET_OUT)/grub/grub_sideload.img
.PHONY : grub_sideload_image

grub_clean:
	if [ -f $(GRUB_OUT)/Makefile ]; then $(MAKE) -C $(GRUB_OUT) clean; fi
	rm -Rf $(GRUB_TARGET_OUT)/*
.PHONY : grub_clean

grub_distclean:
	if [ -f $(GRUB_OUT)/Makefile ]; then $(MAKE) -C $(GRUB_OUT) distclean; fi
	git -C $(GRUB_DIR)/ clean -dfX
	rm -Rf $(GRUB_OUT)/*
	rm -Rf $(GRUB_TARGET_OUT)/*
.PHONY : grub_distclean
