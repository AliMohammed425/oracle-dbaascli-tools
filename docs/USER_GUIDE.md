# ODAA DBaaSCLI Tools User Guide

**Author:** Mohammed Ali  
**Company:** Aqil Information Technology LLC  
**Version:** 5.0.0

## Recommended Workflow

### A. Source / Primary Server

1. Copy the package.

```bash
scp odaa-dbaascli-tools_v5.0.0.zip opc@<primary-host>:/home/opc/
```

2. Unzip and validate config.

```bash
unzip odaa-dbaascli-tools_v5.0.0.zip
cd odaa-dbaascli-tools
chmod +x bin/*.sh lib/*.sh
vi config/migration_db.ini
```

3. Run create precheck if needed.

```bash
bin/odaa_db_create_precheck.sh -p -d <DBNAME> -t
bin/odaa_db_create_precheck.sh -p -d <DBNAME>
```

4. Prepare standby.

```bash
screen -S prepare_<DBNAME>
bin/odaa_db_prepare_stby.sh -d <DBNAME> -t
bin/odaa_db_prepare_stby.sh -d <DBNAME>
```

Follow the instructions from the script output.

### B. Target / Standby Server

1. Copy/unzip the same package and validate the same INI file.

2. Run standby create precheck if required.

```bash
bin/odaa_db_create_precheck.sh -s -d <DBNAME> -t
bin/odaa_db_create_precheck.sh -s -d <DBNAME>
```

3. Build standby.

```bash
screen -S build_<DBNAME>
bin/odaa_db_build_stby.sh -d <DBNAME> -t
bin/odaa_db_build_stby.sh -d <DBNAME>
```

4. Validate status.

```bash
bin/odaa_dg_switchover.sh -s --status -d <DBNAME>
bin/odaa_db_status_health.sh -d <DBNAME>
```

## Testing Mode

Always run with `-t` first when possible.

Testing mode prints the command without making changes.

## Common Troubleshooting

### DB already exists

The create and standby build scripts skip existing database entries when detected from DBaaS inventory.

### flagSkip=Y

Rows with `flagSkip=Y` are skipped.

### Wallet/TDE issues

Validate wallet before standby build:

```sql
set lines 300 pages 100
select wrl_type, status, wallet_type, wallet_order, keystore_mode, wrl_parameter
from v$encryption_wallet;
```

Expected status should normally be `OPEN` for the active keystore.

### DBaaS inventory null values

Use:

```bash
sudo /usr/bin/dbaascli database getDetails --dbname <DBNAME>
sudo /usr/bin/dbaascli database list
```

If inventory is corrupt or incomplete, repair/register the database before retrying automation.
