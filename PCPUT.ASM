;
;  Morrow Disk Jockey 2D Serial Port
;
;  PCPUT - This CP/M program sends a file from a CP/M system to a PC
;  via a serial The file transfer uses the XMODEM protocol. 
;
;  Note this program is gutted from the Ward Christenson Modem program.
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

ERRLMT	EQU	5		;MAX ALLOWABLE ERRORS

;DEFINE ASCII CHARACTERS USED

SOH	EQU	1
EOT	EQU	4
ACK	EQU	6
NAK	EQU	15H
CTRLC	EQU	3		;Control-C
LF	EQU	10
CR	EQU	13

	org	100h

;  Verify a file name was specified

	lda	PARAM1		;A=1st character of parameter 1
	cpi	' '		;make sure file name present
	jnz	haveFn		;yes, have a file name

	lxi	d,mHelp		;display usage message
	mvi	c,PRINT
	call	BDOS
	ret			;return to CPM

haveFn	LXI	H,0		;HL=0
	DAD	SP		;HL=STACK FROM CP/M
	SHLD	STACK		;..SAVE IT
	LXI	SP,STACK	;SP=MY STACK

	xra	a		
	sta	SECTNO		;initialize sector number to zero

	CALL	OPEN$FILE	;OPEN THE FILE

	lxi	d,mRcv		;DE->prompt to receive file
	MVI	C,PRINT
	CALL	BDOS

;  GOBBLE UP GARBAGE CHARS FROM THE LINE

purge	MVI	B,1		;times out after 1 second if no data
	CALL	RECV
	jc	lineClr		;line is clear, go wait for initial NAK

	cpi	CTRLC		;exit if abort requested
	jz	abort

	jmp	purge

; WAIT FOR INITIAL NAK, THEN SEND THE FILE
	
lineClr	xra	a		;clear crc flag = checksum mode
	sta	crcFlag

WAITNAK	MVI	B,1		;TIMEOUT DELAY
	CALL	RECV
	JC	WAITNAK

	cpi	CTRLC		;abort requested?
	jz	abort

	CPI	NAK		;NAK RECEIVED?
	jz	SENDB		;yes, send file in checksum mode

	cpi	'C'		;'C' for CRC mode received?
	JNZ	WAITNAK		;no, keep waiting

	sta	crcFlag		;set CRC flag non-zero = true
				;fall through to start the send operation
;
;*****************SEND A FILE***************
;

;READ SECTOR, SEND IT

SENDB	CALL	READ$SECTOR
	LDA	SECTNO		;INCR SECT NO.
	INR	A
	STA	SECTNO

;SEND OR REPEAT SECTOR

REPTB	MVI	A,SOH
	CALL	SEND

	LDA	SECTNO
	CALL	SEND

	LDA	SECTNO
	CMA
	CALL	SEND

	lxi	h,0		;init crc to zero
	shld	crc16
	mov	c,h		;init checksum in c to zero
	LXI	H,80H

SENDC	MOV	A,M
	CALL	SEND
	call	calCrc		;update CRC
	INX	H
	MOV	A,H
	CPI	1		;DONE WITH SECTOR?
	JNZ	SENDC

; Send checksum or CRC based on crcFlag

	lda	crcFlag		;crc or checksum?
	ora	a
	jz	sndCsum		;flag clear = checksum

	lda	crc16+1		;a=high byte of CRC
	call	SEND		;send it
	lda	crc16		;a=low byte of crc
	jmp	sndSkip		;skip next instruction	

sndCsum	mov	a,c		;send the checksum byte

sndSkip	call	SEND

;GET ACK ON SECTOR

	MVI	B,4		;WAIT 4 SECONDS MAX
	CALL	RECV
	JC	REPTB		;TIMEOUT, SEND AGAIN

;NO TIMEOUT SENDING SECTOR

	CPI	ACK		;ACK RECIEVED?
	JZ	SENDB		;..YES, SEND NEXT SECT

	cpi	ctrlc		;control-c to abort?
	jz	abort

	JMP	REPTB		;PROBABLY NAK - TRY AGAIN
;
;
; S U B R O U T I N E S
;
;OPEN FILE
OPEN$FILE LXI	D,FCB
	MVI	C,OPEN
	CALL	BDOS
	INR	A		;OPEN OK?
	RNZ			;GOOD OPEN

	CALL	ERXIT
	DB	CR,LF,'Can''t Open File',CR,LF,'$'

; - - - - - - - - - - - - - - -
;EXIT PRINTING MESSAGE FOLLOWING 'CALL ERXIT'
ERXIT	POP	D		;GET MESSAGE
	MVI	C,PRINT
	CALL	BDOS		;PRINT MESSAGE

	LHLD	STACK		;GET ORIGINAL STACK
	SPHL			;RESTORE IT
	RET			;--EXIT-- TO CP/M

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

; - - - - - - - - - - - - - - -
;FILE READ ROUTINE
;----------------------------------
READ$SECTOR:
	LXI	D,FCB
	MVI	C,READ
	CALL	BDOS
	ORA	A
	RZ

	DCR	A		;EOF?
	JNZ	RDERR

;EOF

	XRA	A
	STA	ERRCT

SEOT	MVI	A,EOT
	CALL	SEND
	MVI	B,3		;WAIT 3 SEC FOR TIMEOUT
	CALL	RECV
	JC	EOTTOT		;EOT TIMEOUT

	CPI	ACK
	JZ	XFER$CPLT

;ACK NOT RECIEVED

EOTERR	LDA	ERRCT
	INR	A
	STA	ERRCT
	CPI	ERRLMT
	JC	SEOT

	CALL	ERXIT
	db	CR,LF,LF
	db	'No ACK received on EOT, but transfer is complete.',CR,LF,'$'

;
;TIMEOUT ON EOT
;
EOTTOT	JMP	EOTERR
;
;READ ERROR
;
RDERR	CALL	ERXIT
	DB	CR,LF,'File Read Error',CR,LF,'$'

;DONE - CLOSE UP SHOP

XFER$CPLT:
	CALL	ERXIT
	DB	CR,LF,LF,'Transfer Complete',CR,LF,'$'

abort	call	erxit
	DB	CR,LF,LF,'Transfer Aborted',CR,LF,'$'

;-----------------------------------------------------------------------------
; calCrc - update the 16-bit CRC with one more byte. 
;    (Copied from M. Eberhard)
; On Entry:
;   a has the new byte
;   crc16 is current except this byte
; On Exit:
;   crc16 has been updated
;   Trashes a,de
;-----------------------------------------------------------------------------
calCrc	push	b		;save bc, hl
	push	h
	lhld	crc16		;get CRC so far
	xra	h		;XOR into CRC top byte
	mov	h,a
	lxi	b,1021h		;bc=CRC16 polynomial
	mvi	d,8		;prepare to rotate 8 bits

; do 8 bit shift/divide by CRC polynomial

cRotLp	dad	h		;16-bit shift
	jnc	cClr		;skip if bit 15 was 0

	mov	a,h		;CRC=CRC xor 1021H
	xra	b
	mov	h,a
	mov	a,l
	xra	c
	mov	l,a

cClr	dcr	d
	jnz	cRotLp		;rotate 8 times

; save the updated CRC and exit

	shld	crc16		;save updated CRC
	pop	h		;restore hl, bc
	pop	b
	ret

;-----------------------------------------
;  messages
;-----------------------------------------
mHelp	db	CR,LF
	db	'PCPUT ver 1.0 for Disk Jockey 2D Serial Port',CR,LF
	db	LF
	db	'Transmits a file to a PC through a serial port',CR,LF
	db	'using the XMODEM protocol.',CR,LF
	db	LF
	db	'Usage: PCPUT file.ext',CR,LF,'$'

mRcv	db	'Start XMODEM file receive now...$'

; Data Area

	DS	40	;STACK AREA
STACK	DS	2	;STACK POINTER
SECTNO	DS	1	;CURRENT SECTOR NUMBER 
ERRCT	DS	1	;ERROR COUNT
crcFlag	ds	1	;non-zero if using CRC
crc16	ds	2	;computed crc

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
FCB	EQU	5CH	;SYSTEM FCB
PARAM1	EQU	FCB+1	;COMMAND LINE PARAMETER 1 IN FCB
PARAM2	EQU	PARAM1+16	;COMMAND LINE PARAMETER 2
	END
