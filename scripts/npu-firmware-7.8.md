# NPU firmware 7.8: acquisition, CVE check and rollback notes

Companion to `scripts/check-npu-firmware.sh` for roadmap item D12
(security and upstream). The script and this note are a **static
acquisition and verification** step only: they do not replace the NPU
firmware, do not restart the NPU and do not touch a flash partition.

## Current image and the affected range

`CVE-2026-89142` is an out-of-bounds write in the Airoha Wi-Fi NPU
firmware used by EN7529, AN7552, AN7581 and AN7583. The CNA advisory and
the Airoha security bulletin list `TLB7.8.0.0_v006` **and earlier** as
affected:

- <https://www.cve.org/CVERecord?id=CVE-2026-89142>
- <https://www.airoha.com/product-security-bulletin#CVE-2026-89142>

The XR1710G currently ships `en7581_MT7996_npu_rv32.bin` with this
companion data blob:

| file | size | md5 | version string |
| --- | ---: | --- | --- |
| `en7581_MT7996_npu_rv32.bin` | 125832 | `550a8b3bf967a1e83bb1aaeca030ec7b` | `TLB7.7.0.0_v08` |
| `en7581_MT7996_npu_data.bin` | 3092 | `210375f102c7c8a7c41f7a60c83d7652` | none |

The 7.7 image is therefore inside the affected range. The in-tree copy
under `package/firmware/linux-firmware/files/airoha/` is the exact same
blob and can be used as the fixture:

```sh
scripts/check-npu-firmware.sh \
	--firmware-dir package/firmware/linux-firmware/files/airoha
```

The report prints `Result: VULNERABLE-RANGE` and exits 0. The exit status
reports whether the check ran (`0`), found no firmware (`1`) or was
invoked incorrectly (`2`); the verdict is in the report, not in the exit
status.

### 7.8 is not automatically a fixed version

The boundary is inclusive. A build whose version string is exactly
`TLB7.8.0.0_v006` is still affected; only a build strictly later than
`_v006` is outside the CNA range. When the script says `OK`, check that
the version it printed really is later than `TLB7.8.0.0_v006`, for
example `TLB7.8.0.0_v007` or a later 7.9/8.x build.

At the time of writing (2026-11-15) neither the Airoha bulletin nor the
public NPU firmware sources used by this tree published a fixed blob;
`zhengping-zhang/airoha-npu` and the current in-tree blobs are still
7.7.0.0_v08. Treat the 7.8 acquisition below as preparation for a future
change, not as remediation by itself.

## 1. Obtain a complete AN7581/AN7583 firmware image

The NPU blobs are part of the board firmware, not a standalone package,
so start from a full image for a board with AN7581 or AN7583 and a 7.8
NPU build. In order of preference:

1. The board vendor or ISP firmware update for an AN7581/AN7583 device
   known to carry a 7.8 NPU build. Save the original image and its
   release notes.
2. A vendor-supplied NPU firmware drop or SDK update, if the vendor
   distributes one.
3. A device already running 7.8, as a read-only evidence source: copy
   `/lib/firmware/airoha/*.bin` off the device. Do not change that
   device.

Record the provenance before unpacking anything:

```
source URL or vendor case:
device model:
vendor image name and version:
download or dump date:
sha256 of the complete image:
```

Do not commit the vendor image or the extracted blobs to this
repository. Only hashes and short reports belong in git.

## 2. Unpack the image and locate the NPU blobs

The exact container depends on the vendor; these are the common cases.

```sh
mkdir -p ~/npu-7.8 && cd ~/npu-7.8

# Keep the image you actually tested.
sha256sum vendor-image.bin > vendor-image.sha256

# SquashFS root filesystem.
unsquashfs -d rootfs image.squashfs

# UBI/UBIFS root filesystem (package: ubi_reader).
ubireader_extract_images -o ubi image.ubi
ubireader_extract_files -o rootfs ubi/*.ubifs

# Or let binwalk find the containers (binwalk 2.x syntax); it writes to
# _vendor-image.bin.extracted/.
binwalk -e vendor-image.bin
```

Then search the extracted tree (use the directory binwalk created when
that path was used):

```sh
find rootfs -type f \
	\( -name 'en7581*_npu_*.bin' -o -name 'an7583*_npu_*.bin' \)
```

The rv32 image carries the `TLB...` version string; the `_data.bin` file
is the matching data segment. Keep the pair from the same build together;
do not mix an rv32 image from one vendor release with a data blob from
another.

## 3. Check the extracted blobs

Copy only the candidate blobs to a scratch directory and run the checker
with the repository path substituted below:

```sh
# Still in ~/npu-7.8 from step 2.
REPO=/path/to/xr1710g-openwrt
mkdir -p blobs
cp rootfs/lib/firmware/airoha/en7581_MT7996_npu_rv32.bin blobs/
cp rootfs/lib/firmware/airoha/en7581_MT7996_npu_data.bin blobs/

"$REPO/scripts/check-npu-firmware.sh" --firmware-dir "$PWD/blobs" \
	--out npu-7.8-check.txt
```

`--firmware-dir` points at a directory of extracted blobs, `--rootfs` at
an extracted root filesystem, and `--dry-run` prints every path the
script would inspect without opening any of them.

Read the version line, the md5 line, the known-hash line and the final
result together:

- `VULNERABLE-RANGE`: the version is inside the CNA range. Stop here;
  this is not the fixed build.
- `OK`: every version found is later than `TLB7.8.0.0_v006`. Record the
  version and hashes, and keep the complete image for audit.
- `UNKNOWN`: no version string was found (typical for a data-only blob,
  or a stripped image). Inspect it manually and do not treat it as
  fixed.

## 4. Verification checklist

Before a blob is considered a valid 7.8 acquisition:

- [ ] the complete image's sha256 and vendor version are recorded
- [ ] the blobs come from that image, not from a different board/release
- [ ] the rv32 and data blobs are a pair from the same build
- [ ] the rv32 version is strictly later than `TLB7.8.0.0_v006`
- [ ] `scripts/check-npu-firmware.sh` reports `OK` for the pair
- [ ] size and md5 of both blobs are recorded next to the provenance
- [ ] no vendor image or NPU binary is committed to this repository
- [ ] the known-hash table is extended only after the provenance above
      is checked (keep it in sync with this note)

## 5. Rollback prerequisites (for a later installation change)

Replacing the NPU firmware is a separate change and is explicitly out of
scope for this ticket. If it is attempted later, all of the following
must already be true:

- The current known-good 7.7 pair is backed up outside the image:
  `550a8b3bf967a1e83bb1aaeca030ec7b` / `210375f102c7c8a7c41f7a60c83d7652`,
  with their sizes.
- A complete known-good image and a recovery path that does **not**
  depend on the NPU work (U-Boot/chainloader, TFTP or serial console).
  A bad NPU blob can fail probe during boot, so a remote-only recovery
  path is not sufficient.
- Serial console access, and a test on a spare board when possible.
- The flash layout and `compat_version` are known and match the image
  being installed; the current XR1710G layout is `compat_version 2.0`.
- The rollback image has been boot-tested, not just archived.
- The old blobs can be restored in the built image without touching
  unrelated partitions.
- Post-install checks are defined: NPU probe in `dmesg`, PPE bind/offload,
  Wi-Fi traffic on all bands, and no new warnings from the Airoha NPU
  driver.

The rollback action itself is to boot the previous complete image with
the old pair, because the NPU firmware is part of the image. That is why
the old image has to be boot-tested in advance; this document does not
provide an install or rollback command.

## 6. Adding a verified image to the known-hash table

The table in `scripts/check-npu-firmware.sh` (`known_hash()`) maps an md5
to a release label. Add a new entry only when:

1. the blob's provenance is recorded in this file;
2. its version was read with `strings` and checked against the CVE
   boundary;
3. the rv32/data pair has been checked together.

Keep the hash table small and factual; it is a corroboration aid, not a
substitute for reading the version string.
