#mysqldump -u barbie --skip-add-locks --add-drop-table --skip-disable-keys --skip-extended-insert reports >cgi-bin/db/reports-backup.sql
#mysqldump -u barbie --skip-add-locks --add-drop-table --skip-disable-keys --skip-extended-insert reports monitor >cgi-bin/db/monitor.sql
mysqldump -u barbie --skip-add-locks --add-drop-table --skip-disable-keys --skip-extended-insert --ignore-table=reports.reports_hits reports >cgi-bin/db/reports-backup.sql
