.POSIX:
.SILENT:
.PHONY: install uninstall

install: ykpgp.sh
	cp ykpgp.sh "${DESTDIR}${PREFIX}/bin/ykpgp"
	chmod 755 "${DESTDIR}${PREFIX}/bin/ykpgp"

uninstall:
	rm -f "${DESTDIR}${PREFIX}/bin/ykpgp"
