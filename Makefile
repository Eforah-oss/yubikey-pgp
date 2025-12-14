.POSIX:
.SILENT:
.PHONY: install uninstall

install: ykpgp.sh ykpgp-present-wrapper.sh
	cp ykpgp.sh "${DESTDIR}${PREFIX}/bin/ykpgp"
	chmod 755 "${DESTDIR}${PREFIX}/bin/ykpgp"
	cp ykpgp-present-wrapper.sh "${DESTDIR}${PREFIX}/bin/ykpgp-present-wrapper"
	chmod 755 "${DESTDIR}${PREFIX}/bin/ykpgp-present-wrapper"

uninstall:
	rm -f "${DESTDIR}${PREFIX}/bin/ykpgp"
