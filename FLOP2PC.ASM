;*****************************************************************************
;
;  Flop2PC - Transfer floppy image to PC over a serial port
;		(for DISK JOCKEY 2D disk controller)
;
;	This program transmits an image of a soft-sectored 8" floppy
;	to a PC. The image is transmitted through a DISK JOCKEY 2D with the
;       PROM at address E000, or a 88-2SIO at I/O address 010h or 012h
;       using the XMODEM protocol.
;
;	The program talks directly to the DJ2D controller and does not require
;	CP/M or an OS to function.
;
;	This program works best if the console port and the transfer port
;	are not the same device. Otherwise, most error messages won't
;	be seen as the file transfer dialog box prevents their display.
;
;	The program runs standalone at 0x100 or under CP/M. The program
;	is exited with a CTRL-C and either warm boots CP/M or just starts
;       over when running stand alone.
;
;	128, 256, 512, and 1024 byte sectors are supported. FLOP2PC will
;	determine the sector length by reading the sector length byte
;	from tracks 0 and 1.
;
;	Double-sided disks are not supported.
;
;	Written by Patrick Linstruth based on FLOP2PC for the Tarbell
;       controller by Mike Douglas.
;
;	Rev	 Date	    Desc
;	1.0	01/15/21    Original
;	1.1	03/02/24    (M. Douglas) Add retries to track read loop,
;			    update the sector interleave mechanism and
;			    how sectors/track, sector length, and track
;			    length are determined.
;
; FLOP2PC first allocates a track buffer by searching for the top of
; memory. The track buffer starts at trkBuf and ends at bufEnd.
; When running under CP/M the top is memory is determined by the
; start of the BIOS.
;
; mainLp is the main loop that reads tracks from disk into trkBuf
; with readTrk. The DJ2D supports different sector sizes. When
; seeking to tracks 0 and 1, sector 1 is read to determine the
; sector length, sectors per track, and track length. The DJ2D
; firmware does not provide a 1791 READ ADDRESS function, so the
; sector is actually read.
;
; readTrk reads all the sectors of the track into trkBuf pointed
; to by trkPtr. After all sectors are read, trkPtr points to the
; end of track data + 1.
;
; When trkBuf will not fit another complete track, sndTrks
; sends trkBuf up to trkPtr in 128 byte packets using
; the Xmodem protocol. When all packets have been sent,
; mainLp reads the next tracks into trkBuf until all tracks
; have been read and sent.
;
;
;                          ************
;                          *  trkBuf  *
;                          ************
; sndPtr increased by +--> *  TRK X   * <--+ trkPtr is increased by
;    length of packet |    ************    | trkLen as tracks are
; as packets are sent +--> *  TRK X+1 * <--+ read from disk
;         over Xmodem |    ************    |
;                     |    * ........ *    |
;                     v    * ........ *    v
;                          * ........ *
;                          ************
;                          *  TRK X+n *
;                          ************
;                          *  bufEnd  * <--- Tracks are read until
;                          ************      trkPtr + trkLen < bufEnd
;
; 1791 Sector Lengths:
;
; 00: 128	1 x 128
; 01: 256	2 x 128
; 02: 512	4 x 128
; 03: 1024	8 x 128
;
;*****************************************************************************

; DISK JOCKEY 2D Prom Address

DJBASE	equ	0E000h
IOBASE	equ	DJBASE+03f8H

; Disk information equates

NUMTRK	equ	77		;number of tracks
MINDRV	equ	0		;first drive number
MAXDRV	equ	3		;max drive number 

LTRKLEN	equ	(8 * 1024)	;length of largest track in bytes
RDTRIES	equ	3		;disk retries per retry step

; Monitor, CP/M boot entry points

MONITOR	set	init		;no monitor, just start over
CPMBOOT	set	0		;CP/M warm boot jump vector

; XMODEM equates

PKTLEN	equ	128		;128 byte xmodem packet length
SOH	equ	001h
EOT	equ	004h
ACK	equ	006h
NAK	equ	015h
EOF	equ	01ah		;ctrl-z character
XMTRIES	equ	10		;number of xmodem retries

; CP/M Equates

WBOOT	equ	0		;warm boot jump vector

; Misc equates

CR	equ	13		;ascii for carriage return
LF	equ	10		;ascii for line feed
DEL	equ	7fh		;ascii DEL
BS	equ	08h		;ascii backspace
CTRLC	equ	03		;ascii for control-c
JMPINST	equ	0c3h		;jump instruction opcode

	org	0100h		;load address
;-----------------------------------------------------------------------------
;   Initialize for transfer
;-----------------------------------------------------------------------------
init	lxi	sp,ourStk	;initialize stack pointer
	call	chkCpm		;set flag for CP/M or not
	call	sizeRam		;determine amount of RAM available
	call	s2Init		;initialize the 88-2SIO ports
	mvi	a,MINDRV	;a=default drive
	sta	drvNum		;need for pgmExit

;  Display welcome message, then get the drive number and port number
;    to use for the transfer from the operator.

	lxi	h,mWelcom	;display welcome message
	call	dispMsg

; getDrv - get drive number or letter from the user.

getDrv	lxi	h,mDrive	;display drive number prompt
	call	dispMsg
	call	rcvCon		;get byte from the console
	ori	20h		;upper case letters to lower case
	cpi	'x'		;exit requested?
	jz	pgmExit		;yes

	lxi	h,baseDrv	;ascii 1st drive - baseDrv = 0
	sub	m
	cpi	MAXDRV-MINDRV+1	;validate >=min drive and <= max drive
	jnc	getDrv		;invalid, prompt again

	adi	MINDRV		;restore offset of 1st drive (if any)
	sta	drvNum		;save the drive number to use
	call	dRestor		;restore to track 0 (selects drive)
	jnc	getPort

	lxi	h,mIdErr	;could not read sector information
	call	dispMsg
	jmp	getDrv

; getPort - get serial port number from the user.

getPort	lxi	h,mPort		;display transfer port prompt
	call	dispMsg
	call	rcvCon		;get byte from the console
	ori	20h		;upper to lower case, nums not affected
	cpi	'x'		;exit requested?
	jz	pgmExit		;yes

	sui	'1'		;'1' - '3' to bianry 0-2
	cpi	3		;validate ascii 1-3
	jnc	getPort		;invalid, prompt again

	sta	xfrPort		;save the port to use

; Prompt the user to start the XMODEM receive operation on the PC. 
;    Wait for a clear receive line for a least one second, then start
;    looking for NAK or 'C' (crc protocol) from the PC

	lxi	h,mStart	;display start file transfer prompt
	call	dispMsg

clrRcv1	mvi	b,2		;2 second timeout
	call	rcvByte		;loop until input clear for 1 second
	jnz	clrRcv1

	xra	a		;set CRC flag to false (checksum mode)
	sta	crcFlag

waitNak	call	chkQuit		;give user chance to abort
	mvi	b,2		;2 second
	call	rcvByte		;wait for a character
	cpi	NAK
	jz	haveNak		;have a NAK, use checksum protocol

	cpi	'C'		;CRC protocol requested?
	jnz	waitNak		;no

	sta	crcFlag		;set crc flag non-zero = CRC mode

;  NAK or 'C' received meaning the XMODEM receive has started. Initialize
;     for the transfer.

haveNak	xra	a		;init track we want to zero
	sta	trkNum
	inr	a		;init xmodem block number to one
	sta	blkNum

;-----------------------------------------------------------------------------
;  mainLp - Loop through all tracks on the disk buffering as many tracks
;    as will fit in RAM before sending via xmodem, then repeat.
;-----------------------------------------------------------------------------
mainLp	lxi	h,trkBuf	;disk buffering always start at trkBuf
	shld	trkPtr

; Read and buffer bufTrks tracks unless all tracks on drive reached first

bufLoop	call	readTrk		;read into trkBuf

	lda	trkNum		;increment track number (preserve HL)
	inr	a
	sta	trkNum	
	cpi	NUMTRK		;done all tracks on the disk?
	jz	sendBuf		;yes, go send the buffered tracks

	lda	trkErr		;read failure on the track?
	ora	a		;if so, send buffered tracks now
	jnz	sendBuf		;so XMODEM won't time out

	xchg			;de=current track pointer
	lhld	trkLen		;fit another whole track?
	dad	d
	xchg			;de=end of next track pointer
	lhld	bufEnd		;hl=end of buffering space
	call	cmpDeHl		;compare current-end
	jc	bufLoop		;still room, keep going	

; Track buffer is full or all tracks have been read. Send the buffered
;    tracks via xmodem.

sendBuf	call	sndTrks		;send the buffered tracks via xmodem
	lda	trkNum
	cpi	NUMTRK		;done all tracks?
	jnz	mainLp		;no, not done yet

; Send EOT and wait for response. Then display the success message and
;    start the program over.

noExtra	call	sndEot		;send and get response for EOT

	call	dRestor		;home

	lxi	h,mDone		;print the all done message
	call	dispMsg

	jmp	getDrv		;start over asking for a drive
	
;-----------------------------------------------------------------------------
; readTrk - read numSecs sectors from the current track into a trkBuf as
;   pointed to by trkPtr. After the track is read, trkPtr is updated
;   by the length of a track to point to the next track buffer. This
;   saved value is also returned in HL.
;-----------------------------------------------------------------------------
readTrk	lxi	h,trkNum	;get desired track from trkNum	
	mov	l,m		;and put into l
	call	dSeek		;seek to the track

	xra	a
	sta	trkErr		;no error on this track yet

; Read an entire track. Tracks are read every other sector because the
;   code in the DJ PROM can't keep up with consecutive sectors. Odd
;   sectors are read first followed by even sectors (e.g., sector 25 to 2
;   provides more time than 26 to 1). 

	mvi	e,0FFh		;e=sector number, start at -1

secLoop	call	chkQuit		;check for ctrl-c from operator
	call	dNxtSec		;e = next sector to read
	call	secOff		;hl->sector in trkBuf
	call	dRead		;read sector e into trkBuf
	jnz	secRtry		;error, run retry logic

nxtSec	lda	numSecs		;loop for all sectors
	cmp	e
	jnz	secLoop

; track is done, set up for next track

	lhld	trkLen
	xchg			;de=track length
	lhld	trkPtr		;hl=current track pointer
	dad	d		;hl=start of next track in trkBuf
	shld	trkPtr		;trkPtr = end of track + 1
	ret

;--------------------------------------------------------------------------
; secRtry - Read error retry logic. Because of the limitations of the
;    DJ PROM, no head movment is done, just more reads.
;--------------------------------------------------------------------------	
secRtry	mvi	a,RDTRIES	;init retry counter
	sta	rdRtry

retryLp	call	chkQuit		;check for ctrl-c	
	call	secOff		;hl->sector buffer
	call	dRead		;read the sector
	jz	nxtSec		;success, retry is done

	lxi	h,rdRtry	;decrement retry counter
	dcr	m
	jnz	retryLp		;try again
	
	call	dspErr		;give up, display the error
	jmp	nxtSec

;-----------------------------------------------------------------------------
; sndTrks - send the tracks buffered in trkBuf via xmodem. trkPtr points
;    to the end+1 of the data to send
;-----------------------------------------------------------------------------
sndTrks	lhld	trkPtr		;hl=end of buffered data + 1
	xchg			;de=end of buffered data + 1
	lxi	h,trkBuf	;trkBuf is initial starting point for

sndLoop	push	d		;save end pointer
	call	sndPkt		;send a packet
	pop	d		;de=end pointer

; At this point, hl->start of next packet and de->last byte read from disk+1.
;    If the next XMODEM packet will go past the end of the disk data,
;    we don't want to send it yet.

	lxi	b,PKTLEN	;bc=length of XMODEM packet
	dad	b		;hl=address at end of NEXT packet + 1
	call	cmpDeHl		;compare disk end - end of next packet
	rc			;done with track buffer, return

	lxi	b,-PKTLEN	;restore hl
	dad	b
	jmp	sndLoop

; sndDone - reset sndPtr to start of track buffer

sndDone	lhld	trkBuf		;hl=trkBuf
	shld	sndPtr		;save address from which to send next time

	ret

;-----------------------------------------------------------------------------
; sndPkt - send an xmodem format 128 byte packet. HL points to the 128 byte
;    buffer to send. On exit, HL points to the next 128 byte boundary.
;-----------------------------------------------------------------------------
sndPkt	mvi	a,XMTRIES	;init retry counter
	sta	xmRetry

; First, send header bytes

reSend	call	chkQuit		;check for ctrl-c
	push	h		;save hl for possible re-send
	mvi	a,SOH		;1st byte is SOH
	call	sndByte
	lda	blkNum		;2nd byte is the block number
	call	sndByte
	cma			;2nd complement of block number
	call	sndByte

; Init checksum and CRC and packet length for transmission of data portion

	xra	a		;init crc
	sta	crc16
	sta	crc16+1
	lxi	d,PKTLEN*256	;d=byte counter, e=0 (checksum)

; Loop sending the data bytes and updating checksum and CRC

pktLoop	mov	a,m
	call	sndByte		;send and update checksum in e
	call	calCrc		;update the CRC
	inx	h		;point to next byte
	dcr	d		;decrement bytes remaining
	jnz	pktLoop

; Send checksum or CRC based on crcFlag

	lda	crcFlag		;crc or checksum?
	ora	a
	jz	sndCsum		;flag clear = checksum

	lda	crc16+1		;a=high byte of CRC
	call	sndByte		;send it
	lda	crc16		;a=low byte of crc
	jmp	sndSkip		;skip next instruction	

sndCsum	mov	a,e		;send the checksum byte

sndSkip	call	sndByte

;  All bytes sent. Wait for the response.

	mvi	b,5		;5 second timeout
	call	rcvByte		;get the response character
	jz	sndFail		;timeout on response

	cpi	ACK		;ack received?
	jnz	sndFail		;no, send failed

	lda	blkNum		;increment block number
	inr	a
	sta	blkNum

	pop	b		;remove pushed hl, but don't clobber hl
	ret

; sndFail - ACK not received, decrement retry and try again.

sndFail	lxi	h,xmRetry	;point to retry counter
	dcr	m
	jz	xmFail		;retries used up, failed xmodem transfer

; If we've had 3 NAKs on the 1st packet and CRC is selected, assume
;   we took so long to send the 1st packet due to disk retries that
;   the receiver has since timed out and switched to checksum

	lda	crcFlag		;are we in CRC mode
	jz	clrRcv2		;no, ignore the rest of this

	lda	blkNum		;on block 1?
	dcr	a
	jnz	clrRcv2		;no, go on

	lda	xmRetry		;failed three times in a row on block 1?
	sui	XMTRIES-3
	jnz	clrRcv2		;no

	sta	crcFlag		;clear crcFlag to force checksum

;  clrRcv2 - wait for one second of line clear time and send packet again.

clrRcv2	mvi	b,2		;2 second timeout
	call	rcvByte		;wait for 1 second of clear line
	jnz	clrRcv2

	pop	h		;restore pointer to the packet
	jmp	reSend		;re-send the packet

;  xmFail - Display failure message then restart program

xmFail	lxi	h,mXmdm		;xmodem failure message
	call	dispMsg

	lxi	sp,ourStk	;initialize stack pointer
	jmp	getDrv		;start over asking for drive

;-----------------------------------------------------------------------------
; calCrc - update the 16-bit CRC with one more byte. 
;    (Copied from M. Eberhard)
; On Entry:
;   a has the new byte
;   crc16 is current except this byte
; On Exit:
;   crc16 has been updated
;   Trashes a,bc
;-----------------------------------------------------------------------------
calCrc	push	d
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
	pop	h
	pop	d
	ret

;-----------------------------------------------------------------------------
;  sndEot - send EOT character and wait for ACK response
;-----------------------------------------------------------------------------
sndEot	mvi	a,XMTRIES	;init retry counter
	sta	xmRetry

reEot	mvi	a,EOT
	call	sndByte
	mvi	b,5		;5 second timeout
	call	rcvByte		;
	jz	eotFail		;timeout

	cpi	ACK		;ack received?
	jnz	eotFail		;no, eot send failed

	ret			;otherwise, we're done.

; timeout waiting for ACK to EOT. Decrement retry counter and try again

eotFail	lxi	h,xmRetry	;point to retry counter
	dcr	m
	jnz	reEot

;just give up - xfer was probably good

	lxi	h,mNoAck
	jmp	dispMsg

;--------------------------------------------------------------
; secOff - calculate sector buffer within trkPtr
; On Entry:
;    trkPtr = start of current track buffer
;    secLen = length of sectors in this track
;    e = sector number
; On Exit:
;    hl = sector buffer within trkPtr
;    e = sector number
; Cobbers:
;    a
;--------------------------------------------------------------
secOff  mov	a,e		;a = sector number
	lhld	secLen		;get sector length
	mov	b,h		;bc = sector length
	mov	c,l
	lhld	trkPtr		;hl = start of current track buffer
	dcr	a		;sector 1?
	jz	secOffD		;yes

secOffL	dad	b		;add sector offset to hl
	dcr	a		;decrement sector
	jnz	secOffL		;loop until done

secOffD	ret			;return hl=sector buffer
	
;-----------------------------------------------------------------------------
; dispMsg - display the null-terminated message passed in hl on the
;    console device. Clobbers b, hl
;-----------------------------------------------------------------------------
dispMsg	mov	a,m		;get the next message byte
	inx	h		;move to next byte
	ora	a		;null terminates
	rz

	mov	b,a		;conOut wants character in b
	call	conOut
	jmp	dispMsg

;-----------------------------------------------------------------------------
; rcvCon - Receive a character from the console device, echo it, then
;   wait for a CR. Exits program if Ctrl-c typed. Returns with invalid
;   character (null) if BS or DEL pressed after 1st character
;   Returns character in a, clobbers b.
;-----------------------------------------------------------------------------
rcvCon	call	conIn		;check for input
	jz	rcvCon		;nothing

	ani	7fh
	cpi	CTRLC		;abort requested?
	jz	pgmExit		;yes

	cpi	CR		;return pressed?
	rz			;yes, don't echo it

	mov	b,a		;conOut needs character in b
	call	conOut		;echo it

; Wait for CR, then return 1st character typed

rcvCr	call	conIn		;check for input
	jz	rcvCr		;nothing

	ani	7Fh
	cpi	CTRLC		;abort requested?
	jz	pgmExit		;yes

	cpi	DEL		;delete
	rz			;yes, return DEL character

	cpi	BS		;backspace?
	rz			;yes, return BS character

	cpi	CR		;return pressed?
	jnz	rcvCr		;no, keep waiting

	mov	a,b		;return 1st character typed
	ret

;-----------------------------------------------------------------------------
; sndByte - send the byte in a through the specified transfer port. 
;     Adds the byte to register e for checksum. Clobbers b.
;     XMODEM send routine assumes serOut returns with a containing
;     the character sent.
;-----------------------------------------------------------------------------
sndByte	mov	b,a		;b=byte to transmit
	add	e		;update checksum
	mov	e,a		;e=updated checksum
	lda	xfrPort		;a=port to use for transfer
	jmp	serOut		;send the character

;-----------------------------------------------------------------------------
; rcvByte - Receive a byte from specified transfer port with a 'b' second
;     timeout. If a timeout occurs, zero is returned in A and the zero 
;     flag is true. Otherwise, the character is returned in A (could be
;     zero) and zero flag is false. ONESEC must be set based on processor
;     speed and the number of cycles in the serIn call + 59. 
;     Clobbers a, b, d, and e.
;-----------------------------------------------------------------------------
rcvByte lxi     d,ONESEC        ;de=cycles through this loop for 1s

rcvWait lda     xfrPort         ;(13) a=port to use for transfer
        call    serIn           ;(17+cycles in serIn)look for a byte
        rnz                     ;(5)byte received

        dcx     d               ;(5)otherwise, decrement timer
        mov     a,d             ;(5)one second expire?
        ora     e               ;(4)
        jnz     rcvWait         ;(10)no, keep waiting
        dcr     b               ;seconds left?
        jnz     rcvWait

	ret			;return with timeout (zero true and in a)

;-----------------------------------------------------------------------------
; dspErr - display the current track and sector number which just had
;     a read error. If this is the first error on a track, the track
;     number is displayed first.
;
;  on entry:
;     e = sector number
;-----------------------------------------------------------------------------
dspErr	lda	trkErr		;test track error flag
	ora	a
	jnz	dspSec		;track already displayed, go display sector

	inr	a		;set track flag non-zero
	sta	trkErr

; First error on this track. Display "Track xx errors: "

	lxi	h,errTrk	;hl->where to put ascii decimal
	lda	trkNum		;a=track with error on it
	call	bin2dec		;track to ascii
	lxi	h,mTrkErr	;display the track error message
	call	dispMsg

; dspSec - display the sector number with an error

dspSec	lxi	h,errSec	;hl->where to put ascii sector
	mov	a,e		;a=sector where error occured
	call	bin2dec
	call	dispMsg		;display the error
	ret

;--------------------------------------------------------------
; bin2dec - Binary byte in A to 2 ASCII digits at (HL)
;   HL is preserved
;--------------------------------------------------------------
bin2dec	mvi	m,' '		;assume zero supression
	sui	10		;value less than 10?
	jc	do1s		;yes, leading blank
	mvi	m,'1'		;have one ten already

loop10	sui	10		;count 10s
	jc	do1s		;done with 10s, do 1s
	inr	m
	jmp	loop10

do1s	adi	'0'+10		;form ASCII 1s digit
	inx	h		;move to 1s position
	mov	m,a
	dcx	h		;restore hl
	ret

;--------------------------------------------------------------
; chkQuit - check for the user to request abort (ctrl-c). If
;    a character is present on the console port, read it and
;    see if ctrl-c. Clobbers A
;--------------------------------------------------------------
chkQuit	call	conIn		;check for console input
	rz

	ani	7fh
	cpi	CTRLC		;abort requested?
	rnz			;no

; Ctrl-C typed while program is running. Return to drive prompt.

	lxi	sp,ourStk	;initialize stack pointer
	jmp	getDrv		;start over asking for drive num

;--------------------------------------------------------------
; pgmExit - Exit to CP/M or to the monitor ROM based on the
;    CP/M flag
;--------------------------------------------------------------
pgmExit	lda	cpmFlag		;running under CP/M?
	ora	a
	jnz	cpmExit		;yes

; Exit to ROM monitor

	lxi	h,mExit		;display "exiting" message
	call	dispMsg
	jmp	MONITOR		;jump to ROM monitor entry point

; CP/M exit. If boot drive was used, prompt user to insert CP/M disk

cpmExit	lda	drvNum		;boot drive used?
	sui	MINDRV
	jnz	noDisk		;not 1, disk prompt not needed

	lxi	h,mCpm		;display "insert cp/m disk"	
	call	dispMsg
	call	rcvCon		;wait for a character

noDisk	mvi	a,MINDRV	;re-select drive A for CP/M 1.4
	sta	drvNum
	call	dSelDrv

	lxi	h,mExit		;display "exiting" message
	call	dispMsg
	jmp	CPMBOOT		;reboot CP/M

;--------------------------------------------------------------
; chkCpm - check if running under CP/M. CP/M flag is set true
;   (non-zero) if yes, cleared otherwise.
;--------------------------------------------------------------
; First, initialize entries for stand-alone

chkCpm	xra	a
	sta	cpmFlag		;clear CP/M flag
	mvi	a,MINDRV+'0'	;ascii for minimum drive number
	sta	mDrvMin		;store in the drive prompt message
	sta	baseDrv		;ascii 1st drive - baseDrv = 0
	mvi	a,MAXDRV+'0'	;ascii for max drive number
	sta	mDrvMax

; Determine if we're under CP/M or standalone. CP/M is assumed if
;   a jump instruction is present at the CP/M warm start location (0)
;   and five more jumps (e.g., a jump table) is present at the
;   jump-to destination.
		
	lda	WBOOT		;see if jump instruction present for CP/M
	cpi	JMPINST
	rnz			;no, not CP/M

; A jump instruction is present at the CP/M warm boot location (0),
;   now see if that jump points to five more jumps. If so, assume CP/M

	lxi	h,WBOOT+1	;point to lsb of jump address
	mov	e,m		;e=low byte of jump
	inx	h
	mov	d,m		;de=destination of jump
	mvi	b,5		;look for 5 more jumps (a jump table)

jmpTest	ldax	d		;a=opcode at jump destination
	sui	JMPINST		;another jump present?
	rnz			;no, not CP/M
	inx	d		;move to next jump
	inx	d
	inx	d
	dcr	b
	jnz	jmpTest

	dcr	a		;a=0ffh
	sta	cpmFlag		;CP/M flag to non-zero = true

; We're running under CP/M. Change drive prompt message to show drive
;    letters instead of drive numbers and change baseDrv to convert
;    an 'A' to the base drive number (MINDRV).

	mvi	a,'A'		;'A' in drive message instead of number
	sta	mDrvMin
	adi	MAXDRV-MINDRV	;max drive letter
	sta	mDrvMax
	mvi	a,'a'		;ascii 1st drive - baseDrv = 0
	sta	baseDrv
	ret

;------------------------------------------------------------------
; sizeRam - determine how much RAM we have for buffering tracks.
;   Sets the bufEnd variable which points to end address of 
;   the last possible track buffer + 1
;------------------------------------------------------------------
; If running under CP/M, use the BIOS pointer to determine the top
;    of available RAM. Otherwise, size RAM manually.

sizeRam	lhld	WBOOT+1		;get address of BIOS jump table+3
	dcx	h		
	dcx	h
	dcx	h		;hl->top of usable ram+1
	lda	cpmFlag		;running under CP/M?
	ora	a
	jnz	ramEnd		;yes, we have the end of RAM

;  Not under CP/M. Find the end of RAM manually.

	lxi	h,(trkBuf+0ffh) AND 0ff00h   ;next 256 byte boundary

ramLoop	mov	a,m		;a=current RAM content
	inr	m		;change RAM
	cmp	m		;did RAM change?
	mov	m,a		;restore RAM
	jz	ramEnd		;end of RAM found

	inr	h		;next page
	jnz	ramLoop

; ramEnd - end of RAM found. Subtract 256 bytes because it seems
;   like a good idea.

ramEnd	dcr	h		;back 1 page
	shld	bufEnd		;save as bufEnd
	ret

;--------------------------------------------------------------------
; cmHlDe - compare HL-DE. Carry set if HL<DE, carry clear if HL>=DE
;--------------------------------------------------------------------
cmpHlDe	mov	a,l		;compare HL-DE, do lsbs first
	sub	e
	mov	a,h		;do msbs
	sbb	d
	ret			;carry set HL<DE, clear HL>=DE

;--------------------------------------------------------------------
; cmDeHl - compare DE-HL. Carry set if DE<HL, carry clear if DE>=HL
;--------------------------------------------------------------------
cmpDeHl	mov	a,e		;compare DE-HL, do lsbs first
	sub	l
	mov	a,d		;do msbs
	sbb	h
	ret			;carry set DE<HL, clear DE>=HL

;--------------------------------------------------------------------
; subDeHl - HL=DE-HL
;--------------------------------------------------------------------
subDeHl	mov	a,e		;subtract DE-HL, do lsbs first
	sub	l
	mov	l,a		;lsb result in l
	mov	a,d		;do msbs
	sbb	h
	mov	h,a		;msb result in h	
	ret

;---------------------------------------------------------------------
; Message constants
;---------------------------------------------------------------------
mWelcom	db	cr,lf,lf
	db	'===== Floppy to PC Disk Image Transfer =====',cr,lf
	db	'      (DJ2D Controller @ E000, ver 1.1)',cr,lf,lf
	db	'Sends an image of an 8" floppy to a PC via the DJ2D'
	db	cr,lf
	db	'or 88-2SIO serial port using the XMODEM protocol.',cr,lf,0

mDrive	db	cr,lf,lf,'Insert and specify source drive ('
mDrvMin	db	'x-'
mDrvMax	db	'x) or X to exit: ',0

mPort	db	cr,lf,lf
	db	'Specify the port to use for file transfer',cr,lf
	db	'  1) DJ2D (which is also the console)',cr,lf
	db	'  2) 88-2SIO port A',cr,lf
	db	'  3) 88-2SIO port B',cr,lf
	db	'Enter 1-3 or X to exit: ',0

mStart	db	cr,lf,lf,'Start XMODEM receive operation on the PC now...',0

mDone	db	cr,lf,lf,'Transfer complete!',cr,lf,0

mNoAck	db	cr,lf,lf,'No ACK received on EOT.',cr,lf,0

mXmdm	db	cr,lf,lf,'XMODEM communication failure',cr,lf,0

mNoTrk0	db	cr,lf,lf,'Seek to track 0 failed',cr,lf,0

mNotRdy	db	cr,lf,lf,'Drive not ready. Insert formatted disk or Ctrl-C',cr,lf,0

mIdErr	db	cr,lf,lf,'Could not read address from track 1.',cr,lf
	db	'Is disk formatted?',cr,lf,0

mTrkErr	db	cr,lf,'Track '
errTrk	db	'xx failed sectors: ',0
errSec	db	'xx ',0

mExit	db	cr,lf,lf,'Exiting...',cr,lf,0

mCpm	db	cr,lf,lf
	db	'Insert CP/M disk into drive A, then press Return...',0

mCrLf	db	cr,lf,0


;****************************************************************************
;
;  Hardware specific console and serial I/O routines. 
;     The following four routines must be written to provide a common
;     interface to the hardware on which this program is running. The
;     port number specified for serIn and serOut matches the port number
;     input from the operator via the port menu.
;
;****************************************************************************

; DJ2D Serial Port Equates

djDat	equ	IOBASE+0
djCtl	equ	IOBASE+1
djDr	equ	004h		;data ready flag
djTbre	equ	008h		;transmit buffer register empty flag

; 88-2SIO Serial Board Equates

s2aCtl	equ	010h		;1st port on 88-2SIO board - control register
s2aDat	equ	011h		;1st port on 88-2SIO board - data register
s2bCtl	equ	012h		;2nd port on 88-2SIO board - control register
s2bDat	equ	013h		;2nd port on 88-2SIO board - data register
s2Rdrf	equ	001h		;read data register full flag
s2Tdre	equ	002h		;transmit data register empty flag
s2Rst	equ	003h		;reset command
s28n1	equ	015h		;8N1 selection
s28n2	equ	011h		;8N2 selection

; 88-SIO Serial board Equates

sioCtl	equ	00h		;control port
sioDat	equ	01h		;data port
sioRdrf	equ	00000001b	;-RX Data register full
sioTdre	equ	10000000b	;-TX Data register empty

; The rcvByte subroutine above times a one second timeout with a code
;    loop that calls the hardware specific serIn routine below. ONESEC
;    must be set based on processor speed and the number of cycles in 
;    the serIn call + 59 cycles for the rcvByte code. 

ONESEC	equ	19231		;rcvByte loop count for 1 second

;----------------------------------------------------------------------------
; s2Init - reset and initialize 88-2SIO ports for 8N1
;----------------------------------------------------------------------------
s2Init	mvi	a,s2Rst		;reset and init 1st 88-2SIO port
	out	s2aCtl
	mvi	a,s28n1		;transfer port as 8N1
	out	s2aCtl

	mvi	a,s2Rst		;reset and init 2nd 88-2SIO port
	out	s2bCtl
	mvi	a,s28n1		;transfer port as 8N1
	out	s2bCtl
	ret	

;----------------------------------------------------------------------------
; conIn - input character from console
;    inputs:
;    outputs: z true if no character present
;	      z false if character returned in a
;    clobbers none
;----------------------------------------------------------------------------
conIn	lda	djCtl		;see if a new character is present
	cma			;status is inverted
	ani	djDr
	rz			;no character, return zero status

	lda	djDat		;return character and non-zero status
	cma			;byte is inverted
	ret	

;----------------------------------------------------------------------------
; conOut - output character to console
;    inputs: b = character to send
;    clobbers a
;----------------------------------------------------------------------------
conOut	lda	djCtl		;wait for OK to transmit
	cma			;status is inverted
	ani	djTbre
	jz	conOut
	mov	a,b		;a=character to transmit
	cma			;byte is inverted
	sta	djDat		;send it
	ret

;----------------------------------------------------------------------------
; Hardware specific I/O
; serIn - input character from port specified in a
;       0 = DJ2D
;       1 = 88-2SIO port A
;       2 = 88-2SIO port B
;    inputs: a = port to read from
;    outputs: z true if no character present
;	      z false if character returned in a
;    clobbers none
; 88-2SIO Port A: 53 cycles including return when no character present
; 88-2SIO Port B: 43 cycles including return when no character present
;-----------------------------------------------------------------------------
serIn	dcr	a		;(5)3-way test
	jz	s2InA		;(10)a was 1: 88-2SIO port A
	jp	s2InB		;(10)a was 2: 88-2SIO port B
				;    a was 0: DJ2D
; Input from DJ2D
djIn	lda	djCtl		;see if a new character is present
	cma			;status is inverted
	ani	djDr
	rz			;no character, return zero status

	lda	djDat		;return character and non-zero status
	cma			;byte is inverted
	ret	

; Input from 88-2SIO port A

s2InA	in	s2aCtl		;(10+1)see if a new character is present
	ani	s2Rdrf		;(7)
	rz			;(10)no character, return zero status
	in	s2aDat		;return character and non-zero status
	ret	
	
; Input from 88-2SIO port B

s2InB	in	s2bCtl		;(10+1)see if a new character is present
	ani	s2Rdrf		;(7)
	rz			;(10)no character, return zero status

	in	s2bDat		;return character and non-zero status
	ret	

;-----------------------------------------------------------------------------
; Hardware specific I/O
; serOut - output character to port specified in a
;       0 = 88-2SIO port A
;       1 = 88-2SIO port B
;       2 = 88-SIO
;    inputs: a = port to transmit through
;	     b = character to send
;   outputs: a = character sent
;-----------------------------------------------------------------------------
serOut	dcr	a		;3-way test
	jz	s2OutA		;a was 1: 88-2SIO port A
	jp	s2OutB		;a was 2: 88-2SIO port B
				;a was 0: DJ2D
; Send character through DJ2D

djOut	lda	djCtl		;wait for OK to transmit
	cma			;status is inverted
	ani	djTbre
	jz	djOut
	mov	a,b		;a=character to transmit
	cma			;byte is inverted
	sta	djDat		;send it
	cma			;uninvert
	ret

; Send character through 88-2SIO port A

S2OutA	in	s2aCtl		;wait for OK to transmit
	ani	s2Tdre
	jz	S2OutA

	mov	a,b		;a=character to transmit
	out	s2aDat		;send it
	ret

; Send character through 88-2SIO port B

s2OutB	in	s2bCtl		;wait for OK to transmit
	ani	s2Tdre
	jz	s2OutB

	mov	a,b		;a=character to transmit
	out	s2bDat		;send it
	ret

;****************************************************************************
;
; DJ2D disk I/O routines
;
;****************************************************************************

; DJ2D Disk Drive Controller Equates

DBOOT	equ	DJBASE		;DOS bootstrap routine
TERMIN	equ	DJBASE+003H	;serial input
TRMOUT	equ	DJBASE+006H	;serial output
TKZERO	equ	DJBASE+009H	;recalibrate (seek to TRK0)
TRKSET	equ	DJBASE+00CH	;seek
SETSEC	equ	DJBASE+00FH	;select sector
SETDMA	equ	DJBASE+012H	;set DMA address
READ	equ	DJBASE+015H	;read a sector of disk data
WRITE	equ	DJBASE+018H	;write a sector of disk data
SELDRV	equ	DJBASE+01BH	;select a disk drive
TPANIC	equ	DJBASE+01EH	;test for panic character
TSTAT	equ	DJBASE+021H	;serial status input
DMAST	equ	DJBASE+024H	;read current DMA address
STATUS	equ	DJBASE+027H	;disk status input
DSKERR	equ	DJBASE+02AH	;loop to strobe error LED
SETDEN	equ	DJBASE+02DH	;set density
SETSID	equ	DJBASE+030H	;set side for 2-headed drives

;--------------------------------------------------------------
; dRead - Read sector on current track.
; On Entry:
;    Drive is selected, on proper track
;    hl->sector buffer
;    e = sector number to read
; On Exit:
;    Z flag set = good, Z flag clear = error
;    clobbers b,c,h,l
;--------------------------------------------------------------
dRead	push	d		;save de
	mov	c,e		;sector number in c
	call	SETSEC		;set sector
	mov	b,h		;bc = hl
	mov	c,l
	call	SETDMA
	call	READ
	pop	d		;restore de
	ret

;--------------------------------------------------------------
; dSeek - Seek track specified in L.
; On Entry:
;    l = desired track
; On Exit:
;    
; Clobbers none
;--------------------------------------------------------------
dSeek	call	dSelDrv		;make sure drive is selected

	mov	c,l		;track to c
	call	TRKSET		;set track
	cpi	2
	rnc			;return if track > 1

	mvi	e,1		;read sector 1
	lhld	trkPtr		;hl=track pointer
	call	dRead
	call	dSecFmt		;get sector format

	ret

;--------------------------------------------------------------
; dRestor - Selects drive, loads heads and restores to track 0.
;    If restore fails, message display and program restarted
;    at getDrv.
; On Entry:
;    drvNum = drive to be selected and restored to track zero
; On Exit:
;    drive selected and on track zero
; Clobbers none 
;--------------------------------------------------------------
dRestor	call	dSelDrv		;make sure drive is selected
	call	TKZERO
	call	STATUS
	mov	a,c		;get track number
	ora	a		;track 0?
	rz			;yes, return

; restore failed

	lxi	h,mNoTrk0

errMsg	call	dispMsg
	lxi	sp,ourStk	;initialize stack pointer
	jmp	getDrv		;start over asking for drive num

;--------------------------------------------------------------
; dSelDrv - Select drive specified in drvNum 
; On Entry:
;    drvNum = drive to be selected
; On Exit:
;    drive selected
; Clobbers a,c
;--------------------------------------------------------------
dSelDrv	lda	drvNum		;a=desired drive
	mov	c,a
	call	SELDRV
	ret

;--------------------------------------------------------------
; dNextSec - Move to next sector. Reads odd sectors first
;    then even sectors. Very first call for a track should
;    have sector -1 in e.
; On Entry:
;    e = last sector read 
; On Exit:
;    e = new sector to read
; Clobbers e
;--------------------------------------------------------------
dNxtSec	inr	e		;read every other sector
	inr	e
	lda	numSecs		;past end?
	cmp	e
	rnc			;no

	mvi	e,2		;else, do even sectors
	ret

;--------------------------------------------------------------
; dSecFmt - Set sectors per track, sector length, and track
;    length from the most recent sector read.
; On Entry:
;    drive selected
; On Exit:
;    numSecs - sectors per track (26,26,15,8)
;    secLen - sector length (128,256,512,1024)
;    trkLen - track length
;--------------------------------------------------------------
dSecFmt	call	STATUS
	rar			;sector length is bits 2-3
	ani	06h		;a=2*length code
	mvi	d,0		;de=2*length code (16 bit)
	mov	e,a

	lxi	h,sptTbl	;set sectors per track
	dad	d		;index by length code
	mov	a,m
	sta	numSecs
 
	lxi	h,seclTbl	;set sector length
	dad	d		;index by length code
	mov	c,m		;lsb
	inx	h
	mov	h,m		;msb
	mov	l,c		;hl=sector length
	shld	secLen

	lxi	h,trklTbl	;set track length
	dad	d		;index by length code
	mov	c,m		;lsb
	inx	h
	mov	h,m		;msb
	mov	l,c		;hl=track length
	shld	trkLen
	ret

sptTbl	dw	26, 26, 15, 8
seclTbl	dw	128, 256, 512, 1024
trklTbl	dw	26*128, 26*256, 15*512, 8*1024

;**************************************************************************
; 
;  Data area
;
;**************************************************************************
; disk variables

drvNum	ds	1		;drive number to use
trkNum	ds	1		;track number to read
secLen	ds	2		;sector length
numSecs	ds	1		;number of sectors per track
trkLen	ds	2		;track length
trkPtr	ds	2		;pointer into trkBuf at track boundaries
bufEnd	ds	2		;end address + 1 of last track spot in RAM

; retry logic variables

rdRtry	ds	1		;disk read retry counter
rtStep	ds	1		;current retry step
trkErr	ds	1		;non zero if error occured on track

; xmodem variables

xfrPort	ds	1		;pseudo port for file transfer
xmRetry	ds	1		;xmodem retry counter
blkNum	ds	1		;current xmodem block number
crcFlag	ds	1		;non zero if using CRC instead of checksum
crc16	ds	2		;crc-16 result
sndPtr	ds	2		;pointer for start of XMODEM send

; misc variables

cpmFlag	ds	1		;non-zero if running under CP/M
baseDrv	ds	1		;ascii 1st drive - baseDrv = 0
	ds	64		;stack space
ourStk	equ	$

; track buffer runs from here to the end of memory

	ds	PKTLEN		;space for pre-pended unsent data

trkBuf	equ	$

	end

