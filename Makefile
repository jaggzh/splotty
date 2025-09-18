main:
	@echo 'Try:  make vi'
	exit

vi:
	vim Makefile \
		splotty \
		log.splotty.txt \

# Leave blank line above

fns:
	grep -n 'sub ' splotty | batcat --style=numbers -l perl
