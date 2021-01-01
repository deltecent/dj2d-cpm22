;
;  Morrow Disk Jockey 2D Serial Port
;
;  PCGET - This CP/M program receives a file from a PC via a serial 
;  port and writes it to a file on the CP/M system. The file transfer uses
;  the XMODEM protocol. 
;
;  Note this program is gutted from the Ward Christenson Modem program
;
;  Hacked together by Mike Douglas for the Morrow Disk Jockey 2 serial port
;
;	Ver	Date	   Desc
;   	---    --------    -----------------------------------------------
;	1.0    12/24/20    Initial version

;  Serial Port Equates

BASE	EQU	0E000H		;PROM BASE ADDRESS
SIOSR	EQU	BASE+3F9H	;SERIAL PORT STATUS REGISTER
SIODR	EQU	BASE+3F8H	;SERIAL PORT DATA REGISTER

XMTMASK	EQU	08H		;MASK TO ISOLATE XMIT READY BIT
XMTRDY	EQU	00H		;VALUE WHEN READY
RCVMASK	EQU	04H		;MASK TO ISOLATE RECEIVE READY BIT
RCVRDY	EQU	00H		;VALUE WHEN READY

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
	cpi	' '		;make sure file name present
	jnz	haveFn		;yes, have a file name

	lxi	d,mHelp		;display usage message
	mvi	c,PRINT
	call	BDOS
	ret			;return to CPM

haveFn	LXI	SP,STACK	;switch to local stack

	lxi	d,mSend		;send message promt
	MVI	C,PRINT		;print the send message
	CALL	BDOS		;PRINT ID MESSAGE

	xra	a
	sta	SECTNO		;init sector number to zero

;  GOBBLE UP GARBAGE CHARS FROM THE LINE

purge	MVI	B,1		;times out after 1 second if no data
	CALL	RECV
	jc	RECEIVE$FILE	;line is clear, go receive the file

	cpi	CTRLC		;exit if abort requested
	jz	abort

	jmp	purge
;
;**************RECEIVE FILE****************
;
RECEIVE$FILE:
	CALL	ERASE$OLD$FILE
	CALL	MAKE$NEW$FILE
	MVI	A,NAK
	CALL	SEND		;SEND NAK

RECV$LOOP:
RECV$HDR:
	MVI	B,3		;3 SEC TIMEOUT
	CALL	RECV
	JNC	RHNTO		;NO TIMEOUT

RECV$HDR$TIMEOUT:
RECV$SECT$ERR:			;PURGE THE LINE OF INPUT CHARS
	MVI	B,1		;1 SEC W/NO CHARS
	CALL	RECV
	JNC	RECV$SECT$ERR 	;LOOP UNTIL SENDER DONE

	MVI	A,NAK
	CALL	SEND		;SEND NAK
	JMP	RECV$HDR

;GOT CHAR - MUST BE SOH OR CTRL-C TO ABORT

RHNTO:	CPI	SOH
	JZ	GOT$SOH

	cpi	CTRLC		;control-c to abort?
	jz	abort

	CPI	EOT
	JZ	GOT$EOT

	JMP	RECV$SECT$ERR

GOT$SOH:
	MVI	B,1
	CALL	RECV
	JC	RECV$HDR$TIMEOUT

	MOV	D,A		;D=BLK #
	MVI	B,1
	CALL	RECV		;GET CMA'D SECT #
	JC	RECV$HDR$TIMEOUT

	CMA
	CMP	D		;GOOD SECTOR #?
	JZ	RECV$SECTOR

	JMP	RECV$SECT$ERR

;  Receive Sector

RECV$SECTOR:
	MOV	A,D		;GET SECTOR #
	STA	RSECTNO
	MVI	C,0		;INIT CKSUM
	LXI	H,80H		;POINT TO BUFFER

RECV$CHAR:
	MVI	B,1		;1 SEC TIMEOUT
	CALL	RECV		;GET CHAR
	JC	RECV$HDR$TIMEOUT

	MOV	M,A		;STORE CHAR
	INR	L		;DONE?
	JNZ	RECV$CHAR

;VERIFY CHECKSUM

	MOV	D,C		;SAVE CHECKSUM
	MVI	B,1		;TIMEOUT
	CALL	RECV		;GET CHECKSUM
	JC	RECV$HDR$TIMEOUT

	CMP	D		;CHECK
	JNZ	RECV$SECT$ERR

;GOT A SECTOR, WRITE IF = 1+PREV SECTOR

	LDA	RSECTNO
	MOV	B,A		;SAVE IT
	LDA	SECTNO		;GET PREV
	INR	A		;CALC NEXT SECTOR #
	CMP	B		;MATCH?
	JNZ	DO$ACK

;GOT NEW SECTOR - WRITE IT

	LXI	D,FCB
	MVI	C,WRITE
	CALL	BDOS
	ORA	A
	JNZ	WRITE$ERROR

	LDA	RSECTNO
	STA	SECTNO		;UPDATE SECTOR #

DO$ACK	MVI	A,ACK
	CALL	SEND
	JMP	RECV$LOOP

WRITE$ERROR:
	CALL	ERXIT
	DB	CR,LF,LF,'Error Writing File',CR,LF,'$'

GOT$EOT:
	MVI	A,ACK		;ACK THE EOT
	CALL	SEND
	LXI	D,FCB
	MVI	C,CLOSE
	CALL	BDOS
	INR	A
	JNZ	XFER$CPLT

	CALL	ERXIT
	DB	CR,LF,LF,'Error Closing File',CR,LF,'$'
;
ERASE$OLD$FILE:
	LXI	D,FCB
	MVI	C,SRCHF		;SEE IF IT EXISTS
	CALL	BDOS
	INR	A		;FOUND?
	RZ			;NO, RETURN

ERAY:	LXI	D,FCB
	MVI	C,ERASE
	CALL	BDOS
	RET
;
MAKE$NEW$FILE:
	LXI	D,FCB
	MVI	C,MAKE
	CALL	BDOS
	INR	A		;FF=BAD
	RNZ			;OPEN OK

;DIRECTORY FULL - CAN'T MAKE FILE
	CALL	ERXIT
	DB	CR,LF,LF,'Error - Can''t Make File',CR,LF
	DB	'(directory must be full)',CR,LF,'$'
;
; S U B R O U T I N E S
;
; - - - - - - - - - - - - - - -

;EXIT PRINTING MESSAGE FOLLOWING 'CALL ERXIT'

ERXIT	POP	D		;GET MESSAGE
	MVI	C,PRINT
	CALL	BDOS		;PRINT MESSAGE
	JMP	WBOOT

; - - - - - - - - - - - - - - -
;MODEM RECV
;-------------------------------------
RECV	PUSH	D		;SAVE
MSEC	lxi	d,(118 shl 8)	;66 cycles, 8.448ms/wrap*118=1s (2MHz)

MWTI	lda	SIOSR		;(13) character received?
	ANI	RCVMASK		;(7)
	CPI	RCVRDY		;(7)
	JZ	MCHAR		;(10) GOT CHAR

; no character present, decrement timeout

	cpi	0		;(7) waste some time
	cpi	0		;(7) waste some time
	DCR	E		;(5) COUNT DOWN
	JNZ	MWTI		;(10) FOR TIMEOUT

	DCR	D		;do msb every 256th time
	JNZ	MWTI

	DCR	B		;DCR # OF SECONDS
	JNZ	MSEC

;MODEM TIMED OUT RECEIVING

	POP	D		;RESTORE D,E
	STC			;CARRY SHOWS TIMEOUT
	RET

;GOT MODEM CHAR

MCHAR	lda	SIODR		;A=character received
	cma			;data was inverted
	POP	D		;RESTORE DE
	PUSH	PSW		;CALC CHECKSUM
	ADD	C
	MOV	C,A
	POP	PSW
	ORA	A		;TURN OFF CARRY TO SHOW NO TIMEOUT
	RET

; - - - - - - - - - - - - - - -
;MODEM SEND CHAR ROUTINE
;----------------------------------
SEND	PUSH	PSW		;CHECK IF MONITORING OUTPUT
	ADD	C		;CALC CKSUM
	MOV	C,A

SENDW	lda	SIOSR		;ok to transmit?
	ANI	XMTMASK
	CPI	XMTRDY
	JNZ	SENDW

	POP	PSW		;GET CHAR
	cma			;convert to negative data
	sta	SIODR		;send the character
	cma			;restore original value
	RET

;-----------------------------------------
;  messages
;-----------------------------------------
mHelp	db	CR,LF
	db	'PCGET ver 1.0 for Disk Jockey 2D Serial Port',CR,LF
	db	LF
	db	'Receives a file from a PC through a serial port',CR,LF
	db	'using the XMODEM protocol.',CR,LF
	db	LF
	db	'Usage: PCGET file.ext',CR,LF,'$'

mSend	db	'Send file now using XMODEM...$'

;DONE - CLOSE UP SHOP

XFER$CPLT:
	CALL	ERXIT
	DB	CR,LF,LF,'Transfer Complete',CR,LF,'$'

abort:	call	erxit
	db	CR,LF,LF,'Transfer Aborted',CR,LF,'$'

	DS	40	;STACK AREA
STACK	EQU	$

RSECTNO	DS	1	;RECEIVED SECTOR NUMBER
SECTNO	DS	1	;CURRENT SECTOR NUMBER 

;
; BDOS EQUATES (VERSION 2)
;
WBOOT	EQU	0		;WARM BOOT JUMP ADDRESS
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
