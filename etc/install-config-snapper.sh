# Derived from basecamp/omarchy's install/config/snapper.sh (MIT) —
# modifications: filesystem gate for non-btrfs roots (#6683).
SNAPPER_CONFIG_PATH="${OMARCHY_SNAPPER_CONFIG_PATH:-/etc/snapper/configs/root}"
SNAPPER_CONF_PATH="${OMARCHY_SNAPPER_CONF_PATH:-/etc/conf.d/snapper}"
template="${OMARCHY_SNAPPER_TEMPLATE:-${OMARCHY_PATH:-/usr/share/omarchy}/default/snapper/root}"

# Snapshot recovery is filesystem-specific: Snapper and limine-snapper-sync
# only work on btrfs subvolumes. Installing a FSTYPE="btrfs" root config on
# any other filesystem makes snapper-cleanup fail nightly (#6683) and aborts
# the pre-update snapshot — and on ext4, create-config itself fails because
# the Ext4 backend needs /sbin/chsnap, which is not packaged. Gate on the real
# filesystem so non-btrfs roots normalize to "off" instead of failing.
root_fstype="${OMARCHY_SNAPPER_FSTYPE:-$(findmnt -no FSTYPE / 2>/dev/null || true)}"

if [[ $root_fstype == "btrfs" ]]; then
  echo "Configuring Omarchy Snapper snapshot retention"

  if [[ ! -f $SNAPPER_CONFIG_PATH ]]; then
    mkdir -p "$(dirname "$SNAPPER_CONFIG_PATH")"

    if [[ ${OMARCHY_SNAPPER_CONFIGURE_TEST:-0} == "1" ]]; then
      : >"$SNAPPER_CONFIG_PATH"
    else
      snapper --no-dbus -c root create-config / >/dev/null 2>&1 || snapper -c root create-config / >/dev/null
    fi
  fi

  install -m 0644 "$template" "$SNAPPER_CONFIG_PATH"

  mkdir -p "$(dirname "$SNAPPER_CONF_PATH")"
  printf '%s\n' 'SNAPPER_CONFIGS="root"' >"$SNAPPER_CONF_PATH"
  chmod 0644 "$SNAPPER_CONF_PATH"

  systemctl disable --now snapper-timeline.timer >/dev/null 2>&1 || true
  systemctl enable --now snapper-cleanup.timer limine-snapper-sync.service >/dev/null 2>&1 || true
else
  echo "Root is $root_fstype, not Btrfs: keeping Snapper and Limine snapshot sync off"

  # Remove the phantom FSTYPE="btrfs" root config earlier setup wrote here,
  # plus its SNAPPER_CONFIGS entry. Other (genuine) configs are left alone.
  if [[ -f $SNAPPER_CONFIG_PATH ]] &&
    grep -qFx 'FSTYPE="btrfs"' "$SNAPPER_CONFIG_PATH"; then
    rm -f "$SNAPPER_CONFIG_PATH"
  fi

  if [[ -f $SNAPPER_CONF_PATH ]] && grep -qFx 'SNAPPER_CONFIGS="root"' "$SNAPPER_CONF_PATH"; then
    printf '%s\n' 'SNAPPER_CONFIGS=""' >"$SNAPPER_CONF_PATH"
    chmod 0644 "$SNAPPER_CONF_PATH"
  fi

  # Nothing to clean or sync without Btrfs; keep the units from failing daily.
  systemctl disable --now snapper-cleanup.timer >/dev/null 2>&1 || true
  systemctl disable --now limine-snapper-sync.service >/dev/null 2>&1 || true
fi