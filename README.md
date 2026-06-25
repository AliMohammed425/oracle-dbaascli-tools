# DBaaSCLI Tools

**Author:** Mohammed Ali  
**Company:** Aqil Information Technology LLC  
**Version:** 5.0.0 Enterprise Edition  
**Copyright:** Copyright (c) 2026 Aqil Information Technology LLC. All Rights Reserved.

## Purpose

 DBaaSCLI Tools automate Oracle database migration and Data Guard operations using `dbaascli`.

Main use cases:

- Primary and standby database create precheck
- Primary and standby database create
- Prepare primary for standby build
- Build standby and configure Data Guard
- Data Guard status, switchover, failover, snapshot standby, convert back to physical standby
- Database health check
- Move latest DBaaS registration TAR files

## Important Safety Rule

These scripts do **not** delete databases, ASM files, Data Guard configuration, repositories, or existing logs. Existing databases are skipped where detection is possible.

## Folder Structure

```text
odaa-dbaascli-tools/
├── bin/                  # Executable scripts
├── config/               # migration_db.ini and generated TAR files
├── docs/                 # User guide and release notes
├── json/                 # Sample JSON files
├── lib/                  # Shared shell framework
├── logs/                 # Runtime logs and summaries
└── archive/              # Original scripts preserved
```

## Common Options

Most scripts support:

```bash
-a, --all              Run all databases from config
-d, --database <db>    Run one database or comma-separated DB list
-i <file>              Use custom INI file
-t, --test             Testing mode / dry run where supported
-h, --help             Help
```

Create scripts also support:

```bash
-p, --primary          Use primary values from INI
-s, --standby          Use standby values from INI
```

## Usage Examples

### 1. Validate config

```bash
cd odaa-dbaascli-tools
chmod +x bin/*.sh lib/*.sh
vi config/migration_db.ini
```

### 2. Create precheck only

```bash
bin/odaa_db_create_precheck.sh -p -d txndcd01 -t
bin/odaa_db_create_precheck.sh -s -d txndcd01 -t
```

### 3. Create database

```bash
bin/odaa_db_create.sh -p -d txndcd01
bin/odaa_db_create.sh -s -d txndcd01
```

### 4. Prepare standby

Run from the primary side:

```bash
bin/odaa_db_prepare_stby.sh -d txndcd01 -t
bin/odaa_db_prepare_stby.sh -d txndcd01
```

### 5. Build standby and configure Data Guard

Run from the standby/target side as applicable for your DBaaS workflow:

```bash
bin/odaa_db_build_stby.sh -d txndcd01 -t
bin/odaa_db_build_stby.sh -d txndcd01
```

### 6. Data Guard status

```bash
bin/odaa_dg_switchover.sh -p --status --all
bin/odaa_dg_switchover.sh -s --status -d txndcd01
```

### 7. Data Guard switchover

```bash
bin/odaa_dg_switchover.sh -p --switchover -d txndcd01 -t
bin/odaa_dg_switchover.sh -p --switchover -d txndcd01
```

### 8. Health check

```bash
bin/odaa_db_status_health.sh --all
bin/odaa_db_status_health.sh -d txndcd01
```

## INI Format

Header expected:

```text
dbName|dbUniqueName|dbSID|dbCharset|dbNCharset|pdatafileDestination|pfraDestination|pNodeList|port|syspass|tdepass|primaryScanIPAddresses|primaryScanPort|pServiceName|standbyScanIPAddresses|standbyScanPort|sServiceName|standbyDBUniqueName|sdatafileDestination|sfraDestination|sNodeList|flagSkip|dbBlockSizeInKB|enableCDB|dbHome
```

Recommended permissions:

```bash
chmod 600 config/migration_db.ini
chmod 700 bin/*.sh
```

## Log Files

Every run writes logs under:

```text
logs/
```

Each run creates:

- Master log
- Summary log

## GitHub Upload

```bash
git init
git add .
git commit -m "Initial ODAA DBaaSCLI Tools v5.0.0"
git branch -M main
git remote add origin git@github.com:<your-user>/<repo-name>.git
git push -u origin main
```

