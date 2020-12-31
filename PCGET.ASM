;
;  PCGET - This CP/M program receives a file from a PC via a serial 
;  port and writes it to a file on the CP/M system. The file transfer uses
;  the XMODEM protocol. 
;
;  Note this program is gutted from PCGET 1.2 by Mike Douglas for the
;  Altair 2SIO
;
;  Hacked together by Patrick Linstruth for the DISK JOCKEY 2D
;	Ver	Date	Desc
;	1.0   12/30/20	Initial version
;
;  Serial Port Equates

SIOBASE	EQU	0E000H		;DJ2D register base address
SIOADR	EQU	SIOBASE+03F8H	;DJ2D data address
SIOACR	EQU	SIOBASE+03F9H	;DJ2D status address

XMTMASK	EQU	8		;MASK TO ISOLATE XMIT READY BIT
XMTRDY	EQU	8		;VALUE WHEN READY
RCVMASK	EQU	4		;MASK TO ISOLATE RECEIVE READY BIT
RCVRDY	EQU	4		;BIT ON WHEN READY

;  Transfer related equates

SOH	EQU	1
EOT	EQU	4
ACK	EQU	6
NAK	EQU	15H
CTRLC	EQU	3		;Control-C
LF	EQU	10
CR	EQU	13

	ORG	100H

;  Verify a file name was specified

	lda	PARAM1		;A=1st character of parameter 1
	cpi	' '		;make sure something entered
	jnz	doXfer
	lxi	d,mHelp		;display usage message
	mvi	c,print
	call	bdos
	ret			;return to CPM

;  doXfer - Switch to local stack and do the transfer

doXfer	lxi	h,0		;HL=0
	dad	sp		;HL=STACK FROM CP/M
	shld	STACK		;..SAVE IT
	lxi	SP,STACK	;SP=MY STACK
	xra	a
	sta	SECTNO		;init sector number to zero
	lxi	d,mSendA	;send message
	mvi	c,PRINT		;print the send message
	call	BDOS		;PRINT ID MESSAGE

;  GOBBLE UP GARBAGE CHARS FROM THE LINE

purge	mvi	b,1		;times out after 1 second if no data
	call	RECV
	jc	RECEIVE$FILE	;line is clear, go receive the file
	cpi	CTRLC		;exit if abort requested
	jz	abort
	jmp	purge
;
;**************RECEIVE FILE****************
;
RECEIVE$FILE:
	call	ERASE$OLD$FILE
	call	MAKE$NEW$FILE
	mvi	a,NAK
	call	SEND		;SEND NAK

RECV$LOOP:
RECV$HDR:
	mvi	b,3		;3 SEC TIMEOUT
	call	RECV
	jnc	RHNTO		;NO TIMEOUT

RECV$HDR$TIMEOUT:
RECV$SECT$ERR:			;PURGE THE LINE OF INPUT CHARS
	mvi	b,1		;1 SEC W/NO CHARS
	call	RECV
	jnc	RECV$SECT$ERR 	;LOOP UNTIL SENDER DONE
	mvi	a,NAK
	call	SEND		;SEND NAK
	jmp	RECV$HDR

;GOT CHAR - MUST BE SOH OR CTRL-C TO ABORT

RHNTO:	cpi	SOH
	jz	GOT$SOH
	cpi	CTRLC		;control-c to abort?
	jz	abort
	cpi	EOT
	jz	GOT$EOT
	jmp	RECV$SECT$ERR

GOT$SOH:
	mvi	b,1
	call	RECV
	jc	RECV$HDR$TIMEOUT
	mov	d,A		;D=BLK #
	mvi	b,1
	call	RECV		;GET cma'D SECT #
	jc	RECV$HDR$TIMEOUT
	cma
	cmp	d		;GOOD SECTOR #?
	jz	RECV$SECTOR
	jmp	RECV$SECT$ERR

;  Receive Sector

RECV$SECTOR:
	mov	a,D		;GET SECTOR #
	sta	RSECTNO
	mvi	c,0		;INIT CKSUM
	lxi	h,80H		;POINT TO BUFFER
RECV$CHAR:
	mvi	b,1		;1 SEC TIMEOUT
	call	RECV		;GET CHAR
	jc	RECV$HDR$TIMEOUT
	mov	m,A		;STORE CHAR
	inr	l		;DONE?
	jnz	RECV$CHAR

;VERIFY CHECKSUM

	mov	d,C		;SAVE CHECKSUM
	mvi	b,1		;TIMEOUT
	call	RECV		;GET CHECKSUM
	jc	RECV$HDR$TIMEOUT
	cmp	d		;CHECK
	jnz	RECV$SECT$ERR
;
;GOT A SECTOR, WRITE IF = 1+PREV SECTOR
;
	lda	RSECTNO
	mov	b,A		;SAVE IT
	lda	SECTNO		;GET PREV
	inr	a		;CALC NEXT SECTOR #
	cmp	b		;MATCH?
	jnz	DO$ACK

;GOT NEW SECTOR - WRITE IT

	lxi	D,FCB
	mvi	c,WRITE
	call	BDOS
	ora	a
	jnz	WRITE$ERROR
	lda	RSECTNO
	sta	SECTNO		;UPDATE SECTOR #
DO$ACK	mvi	a,ACK
	call	SEND
	jmp	RECV$LOOP

WRITE$ERROR:
	call	ERXIT
	db	13,10,10,'Error Writing File',13,10,'$'

GOT$EOT:
	mvi	a,ACK		;ACK THE EOT
	call	SEND
	lxi	D,FCB
	mvi	c,CLOSE
	call	BDOS
	inr	a
	jnz	XFER$CPLT
	call	ERXIT
	db	13,10,10,'Error Closing File',13,10,'$'
;
ERASE$OLD$FILE:
	lxi	D,FCB
	mvi	c,SRCHF		;SEE IF IT EXISTS
	call	BDOS
	inr	a		;FOUND?
	rz			;NO, RETURN
ERAY:	lxi	D,FCB
	mvi	c,ERASE
	call	BDOS
	ret
;
MAKE$NEW$FILE:
	lxi	D,FCB
	mvi	c,MAKE
	call	BDOS
	inr	a		;FF=BAD
	rnz			;OPEN OK

;DIRECTORY FULL - CAN'T MAKE FILE
	call	ERXIT
	db	13,10,10,'Error - Can''t Make File',13,10
	db	'(directory must be full)',13,10,'$'
;
; S U B R O U T I N E S
;
; - - - - - - - - - - - - - - -

;EXIT PRINTING MESSAGE FOLLOWING 'CALL ERXIT'

ERXIT	pop	D		;GET MESSAGE
	mvi	c,PRINT
	call	BDOS		;PRINT MESSAGE
EXIT	lhld	staCK		;GET ORIGINAL STACK
	sphl			;RESTORE IT
	ret			;--EXIT-- TO CP/M

; - - - - - - - - - - - - - - -
;MODEM RECV
;-------------------------------------
RECV	push	D		;SAVE
MSEC	lxi	d,(159 shl 8)	;49 cycle loop, 6.272ms/wrap * 159 = 1 second

MWTI	lda	SIOACR
	cma			;INVERTED
	ani	RCVMASK
	cpi	RCVRDY
	jz	MCHAR		;GOT CHAR
	dcr	e		;COUNT DOWN
	jnz	MWTI		;FOR TIMEOUT
	dcr	d
	jnz	MWTI
	dcr	b		;DCR # OF SECONDS
	jnz	MSEC

;MODEM TIMED OUT RECEIVING

	pop	D		;RESTORE D,E
	stc			;CARRY SHOWS TIMEOUT
	ret

;GOT MODEM CHAR

MCHAR	lda	SIOADR
	cma			;INVERTED
	pop	D		;RESTORE DE
	push	PSW		;CALC CHECKSUM
	add	c
	mov	c,A
	pop	PSW
	ora	a		;TURN OFF CARRY TO SHOW NO TIMEOUT
	ret

; - - - - - - - - - - - - - - -
;MODEM SEND CHAR ROUTINE
;----------------------------------
;
SEND	push	PSW		;CHECK IF MONITORING OUTPUT
	add	c		;CALC CKSUM
	mov	c,A
SENDW	lda	SIOACR
	cma			;INVERTED
	ani	XMTMASK
	cpi	XMTRDY
	jnz	SENDW
	pop	PSW		;GET CHAR
	cma			;INVERTED
	sta	SIOADR
	ret

mSendA	db	'Send the file now using XMODEM...$'
mHelp	db	CR,LF,'PCGET Ver 1.0 for DJ2D',CR,LF,LF
	db	'Usage: PCGET file.ext',CR,LF,'$'

;DONE - CLOSE UP SHOP

XFER$CPLT:
	call	ERXIT
	db	13,10,10,'Transfer Complete',13,10,'$'

abort:	call	erxit
	db	13,10,10,'Transfer Aborted',13,10,'$'

	DS	40	;STACK AREA
STACK	DS	2	;STACK POINTER
RSECTNO	DS	1	;RECEIVED SECTOR NUMBER
SECTNO	DS	1	;CURRENT SECTOR NUMBER 
;
; BDOS EQUATES (VERSION 2)
;
RDCON	EQU	1
WRCON	EQU	2
PRINT	EQU	9
CONST	EQU	11	;CONSOLE STAT
OPEN	EQU	15	;0FFH=NOT FOUND
CLOSE	EQU	16	;   "	"
SRCHF	EQU	17	;   "	"
SRCHN	EQU	18	;   "	"
ERASE	EQU	19	;NO RET CODE
READ	EQU	20	;0=OK, 1=EOF
WRITE	EQU	21	;0=OK, 1=ERR, 2=?, 0FFH=NO DIR SPC
MAKE	EQU	22	;0FFH=BAD
REN	EQU	23	;0FFH=BAD
STDMA	EQU	26
BDOS	EQU	5
REIPL	EQU	0
FCB	EQU	5CH	;DEFAULT FCB
PARAM1	EQU	FCB+1	;COMMAND LINE PARAMETER 1 IN FCB
PARAM2	EQU	PARAM1+16	;COMMAND LINE PARAMETER 2
	END
