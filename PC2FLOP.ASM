;******************************************************************************
;
;  PC2Flop - Transfer disk image from PC to floppy over serial port.
;		(for DISK JOCKEY 2D disk controller)
;
;	This program writes a soft-sectored 8" floppy with a disk image
;	transmitted from a PC. The image is transmitted through the DJ2D
;	serial port or an 88-2SIO at I/O address 010h or 12h using the
;	XMODEM protocol.
;
;	The program talks directly to the DJ2D controller and does not
;	require CP/M or an OS to function.
;
;	This program works best if console port and the transfer port
;	are not the same device. Otherwise, most error messages won't
;	be seen as the file transfer dialog box prevents their display.
;
;	The program runs standalone at 0x100 or under CP/M. The program
;	is exited with a CTRL-C and either warm boots CP/M or just starts
;       over when running stand alone.
;
;	128, 256, 512, and 1024 byte sectors are supported. PC2FLOP will
;	determine the sector length by reading the sector length byte
;	off tracks 0 and 1. The image being sent from the PC must match
;	the format for the disk inserted into the destination drive.
;
;	Double-sided disks are not supported.
;
;	Written by Patrick Linstruth based on PC2FLOP for the Tarbell
;       controller by Mike Douglas.
;
;	Rev	 Date	    Desc
;	1.0	01/17/21    Original
;	1.1	03/02/24    (M. Douglas) Update the sector interleave
;			    mechanism and how sectors/track, sector length,
;			    and track length are determined.
;
;*****************************************************************************

; DISK JOCKEY 2D Prom Address

DJBASE	equ	0E000h
IOBASE	equ	DJBASE+03f8H

; Disk information equates

NUMTRK	equ	77		;number of tracks
MINDRV	equ	0		;first drive number
MAXDRV	equ	3		;max drive number 

RDTRIES	equ	5		;number of read (verify) attempts
WRTRIES	equ	4		;number of write attempts

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

; CP/M Equates

WBOOT	equ	0		;warm boot jump location

; Misc equates

CR	equ	13		;ascii for carriage return
LF	equ	10		;ascii for line feed
DEL	equ	7fh		;ascii DEL
BS	equ	08h		;ascii backspace
CTRLC	equ	03		;ascii for control-c
JMPINST	equ	0c3h		;jump instruction opcode

	org	0100h	
;-----------------------------------------------------------------------------
;  Initialize for transfer
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

; Restore to track 0, verify drive is not write protected

	call	dRestor		;restore to track 0

; Verify writes?

	xra	a		;clear verify flag
	sta	vfyFlag

vfyReq	lxi	h,mVerify	;display verify prompt
	call	dispMsg
	call	rcvCon		;get byte from the console
	ori	20h		;upper case letters to lower case

	cpi	'n'		;request verify?
	jz	getPort		;no

	cpi	'y'		;request verify?
	jnz	vfyReq		;invalid response, retry	
	sta	vfyFlag		;else make vfyFlag non-zero (true)

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

; Prompt the user to insert the disk to write, initialize, then start
;   sending NAK to start the XMODEM reception.

	lxi	h,mStart	;display start file transfer prompt
	call	dispMsg

	xra	a		;init track we're reading to zero
	sta	trkNum
	sta	eotFlag		;clear EOT flag

	inr	a		;init xmodem block number to one
	sta	blkNum

	lxi	h,trkBuf	;trkBuf is initial starting point for
	shld	rcvPtr		;   XMODEM receive

	mvi	a,NAK		;send starting nak after purging input data
	call	purgSio

;-----------------------------------------------------------------------------
;  mainLp - Receive as many packets as will fit into RAM and then write
;      tracks to disk. Repeat until entire disk is written. 
;-----------------------------------------------------------------------------
mainLp	lda	eotFlag		;check for EOT
	ora	a
	jnz	allDone		;if EOT, all done

	call	bufPkts		;buffer as many packets as possible
	xchg			;de=start of last packet received
	lxi	h,trkBuf	;hl=start of track buffer
	shld	trkPtr		;writing will start from here
	call	cmpDeHl		;compare last packet start - trkBuf
	jc	allDone		;nothing received but an EOT

; trkLoop - write tracks until all disk tracks have been written or all
;    the tracks in the buffer have been written.
	
trkLoop	call	wrtTrk		;write a track (hl=next track pointer)

	lda	trkNum		;increment track number
	inr	a
	sta	trkNum	
	cpi	NUMTRK		;done all tracks?
	jz	allDone		;yes

	call	dSeek		;seek to next track and read format

	xchg			;de=next track pointer
	lhld	rcvPtr		;hl=start of last packet received
	call	subHlDe		;hl=hl-de (bytes remaining)

	push	h		;save bytes remaining
	push	d		;save next track pointer
	xchg			;de=bytes remaining
	lhld	trkLen		;hl=track length
	call	cmpDeHl		;de >= he
	pop	d		;de=next track pointer
	pop	b		;bc=bytes remaining
	jnc	trkLoop		;another full track is present

; If there is an incomplete track remaining in trkBuf, move remaining bytes
;     to start of trkBuf and set rcvPtr

	lxi	h,trkBuf	;hl=start of trkBuf
	mov	a,b		;any bytes to move?
	ora	c		;
	jz	mvDone		;no, skip move

moveLp	ldax	d		;move from end of trkBuf to start of trkBuf
	mov	m,a
	inx	h		;hl->starting bytes of trkBuf
	inx	d		;de->unwritten bytes from end of trkBuf
	dcx	b
	mov	a,b
	ora	c
	jnz	moveLp

mvDone	shld	rcvPtr		;save address where to receive next packet

	mvi	a,ACK		;ACK the last packet or EOT
	call	sndByte

	jmp	mainLp		;go receive more packets

; allDone - The disk is completely written. ACK the final packet (or EOT),
;     display the "transfer complete" message and start the program over.

allDone	mvi	a,ACK		;ACK the final packet or EOT
	call	sndByte

	call	dRestor		;home drive head

	lxi	h,mDone		;hl->done message
	call	dispMsg
	jmp	getDrv		;start over asking for drive num


;-----------------------------------------------------------------------------
; bufPkts - Receive XMODEM packets until we fill all the track buffer
;   space available. Reception starts at the address pointed to by
;   rcvPtr. Reception is stopped when trkBuf is full.
;   rcvPtr is updated on exit to point to the start of the last packet received.
;   The disk write routines use this pointer to know where data ends and
;   then update rcvPtr to start to where to begin receiving new packets.
;-----------------------------------------------------------------------------
bufPkts	call	rcvPkt		;receive a packet
	xchg			;de=current xmodem receive pointer
	cpi	EOT		;EOT received?
	jz	bufDone		;yes, buffering is done

	lhld	bufEnd		;hl=end of buffering space
	call	cmpDeHl		;compare current-end	
	jnc	bufDone		;past or at end, buffering is done

	mvi	a,ACK		;otherwise, ACK the packet
	call	sndByte
	xchg			;put xmodem rcv pointer back in HL
	jmp	bufPkts		;buffer some more

; bufDone - no more room for packets. Update rcvPtr to point to the 
;   start of the last packet received so the disk write routines know
;   where data ends.

bufDone	xchg			;hl=current xmodem receive pointer
	shld	rcvPtr		;save use by write tracks
	ret

;-----------------------------------------------------------------------------
; rcvPkt - receive an xmodem format 128 byte packet. HL points to the 128 byte
;    buffer to receive. HL is updated by 128 bytes after each succuessful
;    reception of a new 128 byte packet.
;-----------------------------------------------------------------------------
nakPkt	pop	h		;get HL back
	mvi	a,NAK
	call	purgSio		;purge receive for 1s then transmit NAK

;wait for SOH or EOT

rcvPkt	push	h		;save HL for retries

waitSoh	call	chkQuit		;check for user abort
	mvi	a,3		;3 second timeout for soh
	call	rcvByte		;receive character with timeout
	jz	nakPkt		;timeout

	cpi	SOH		;SOH received?
	jz	haveSoh

	cpi	EOT		;EOT to say we're done?
	jnz	waitSoh		;no, keep looking for SOH
	sta	eotFlag		;set EOT flag

	pop	h		;undo the entry push
	ret			;return with EOT

;  Have SOH, receive block number and not block number

haveSoh	mvi	a,1		;one second timeout once inside a packet
	call	rcvByte		;get the block number
	jz	nakPkt		;timeout, NAK and start over

	sta	rcvBlk		;save the received block number
	mvi	a,1		;one second timeout
	call	rcvByte		;get not block number
	jz	nakPkt		;timeout, NAK and start over

	sta	rcvNBlk		;save not block number

;  Receive the 128 byte block

	mvi	e,0		;init checksum
	mvi	d,pktLen	;d is byte counter

pktLoop	mvi	a,1		;one second timeout
	call	rcvByte		;get next data byte
	jz	nakPkt		;timeout

	mov	m,a		;store the character
	inx	h		;point to next byte
	add	e		;update the checksum
	mov	e,a
	dcr	d		;decrement bytes remaining
	jnz	pktLoop

;  Verify the checksum

	mvi	a,1		;one second timeout
	call	rcvByte		;get the checksum
	jz	nakPkt		;timeout

	cmp	e		;checksum match?
	jnz	nakPkt		;no, packet error

;  Checksum good. Verify block numbers

	lda	rcvNBlk		;verify rcvBlk = not (rcvNBlk)
	cma			;A should = block number now
	mov	b,a		;save in b
	lda	rcvBlk
	cmp	b		;compare rcvBlk = not(rcvNBlk)?
	jnz	nakPkt		;no, error

	lda	blkNum		;compare rcvBlk = expected blkNum
	cmp	b
	jnz	nakPkt		;nak if not the same (also nak's re-send)

	inr	a		;increment expected block number
	sta	blkNum
	pop	b		;get HL off stack, but don't clobber HL
	xra	a		;return a zero
	ret

;-----------------------------------------------------------------------------
; wrtTrk - write and verify numSecs sectors to the current track in trkBuf
;   as pointed to by trkPtr. After the track is written, trkPtr is updated
;   by the length of a track to point to the next track buffer. This
;   saved value is also returned in HL.
;-----------------------------------------------------------------------------
wrtTrk	mvi	a,WRTRIES	;init write retry counter
	sta	wrRetry

; rtryWrt - write a track and the retry entry point.

rtryWrt	mvi	e,0FFh		;e=sector number, start at -1
	
; wrtLoop - write a full track starting after the sector in e.

wrtLoop	call	dNxtSec		;e=sector to write
	call	secOff		;set hl to sector trkPtr offset
	call	dWrite		;write hl to sector e
	jnz	wrtErr		;z clear = write failed

	lda	numSecs		;loop for all sectors
	cmp	e
	jnz	wrtLoop

; Verify the track just written

	mvi	e,0FFh		;e=sector number, start at -1

vfyLoop	call	chkQuit		;check for ctrl-c
	call	dNxtSec		;e=sector to verify
	lxi	h,secBuf	;temporary sector buffer
	call	dVerify		;verify the sector
	jnz	vfyRtry		;error, go to retry logic

vfyNext	lda	numSecs		;loop for all sectors
	cmp	e
	jnz	vfyLoop

; Track verified, set up for next track

skipVfy	lhld	trkLen		;get track length
	xchg			;de = track length
	lhld	trkPtr		;hl = trkPtr
	dad	d		;hl = hl + de
	shld	trkPtr		;save start of next track buffer
	ret

; vfyRtry - verify failed, retry reads followed by a re-write
;   of the track in needed.

vfyRtry	mvi	a,RDTRIES	;init retry counter
	sta	rdRetry

retryLp	call	chkQuit		;check for ctrl-c
	lxi	h,secBuf	;hl->temporary sector buffer
	call	dVerify		;verify the sector
	jz	vfyNext		;success, go verify next sector

; Re-verify failed. Decrement retry count and try again if not zero. Once
;   retry counter expires, do another write.

	lxi	h,rdRetry	;decrement the read retry counter
	dcr	m
	jnz	retryLp		;try again

; Write verify failed. Decrement the retry count and re-write if the count
;    is not zero

	lxi	h,wrRetry	;decrement the write retry counter
	dcr	m
	jnz	rtryWrt		;retry starting with the write

	jmp	vfyErr		;display the error and restart

;-----------------------------------------------------------------------------
; Disk write verify failure. Display the track and sector with the error. 
;    Restart the program.
;-----------------------------------------------------------------------------
wrtErr	call	dChkErr		;display error

vfyErr	lxi	h,errTrk	;hl->where to put ascii decimal
	lda	trkNum		;a=track with error on it
	call	bin2dec		;track to ascii

	lxi	h,errSec	;hl->where to put ascii sector
	mov	a,e		;a=sector where error occured
	call	bin2dec

	lxi	h,mDskErr	;display the error message
	call	dispMsg
	lxi	sp,ourStk	;initialize stack pointer
	jmp	getDrv		;start over asking for drive num

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
	lhld	trkPtr		;hl = start of curruent track buffer
	dcr	a		;sector 1?
	rz			;yes, return

secOffL	dad	b		;add sector offset to hl
	dcr	a		;decrement sector
	jnz	secOffL		;loop until done

	ret			;return hl=sector buffer

;-----------------------------------------------------------------------------
; dispMsg - display the null-terminated message passed in hl on the
;    console device. Clobbers b, hl
;-----------------------------------------------------------------------------
dispMsg	mov	a,m		;get the next message byte
	ora	a		;null terminates
	rz

	mov	b,a		;conOut wants character in b
	call	conOut
	inx	h		;move to next byte
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

	ani	7fh
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
; purgSio - wait for 1 second of idle time on receive line, then transmit the
;	character passed in A (usually ACK or NAK). Clobbers b
;-----------------------------------------------------------------------------
purgSio	push	a

purge	mvi	a,1		;1 second timeout
	call	rcvByte		;wait for 1 second without activity
	jnz	purge

	pop	a		;get back the character to send
				;fall through to sndByte
;-----------------------------------------------------------------------------
; sndByte - send the byte in a through the specified transfer port. 
;     Clobbers b. (assuming serOut clobbers only a).
;-----------------------------------------------------------------------------
sndByte	mov	b,a		;b=byte to transmit
	lda	xfrPort		;a=port to use for transfer
	jmp	serOut		;send the character


;-----------------------------------------------------------------------------
; rcvByte - Receive a byte from the specified transfer port. A wait timeout
;     in seconds is specified in a. If a timeout occurs, zero is returned in
;     a and the zero flag is true. Otherwise, the character is returned in a 
;     (could be zero) and the zero flag is false. ONESEC must be set based
;     on processor speed and the number of cycles in the serIn call + 59.
;     Clobbers a, b and c.
;-----------------------------------------------------------------------------
rcvByte	push	d		;save d, e
	mov	d,a		;save timeout in d

initSec	lxi	b,ONESEC	;one second timeout 104 cycles per loop

rcvWait	lda	xfrPort		;(13) a=port to use for transfer
	call	serIn		;(17+45) look for a byte
	jnz	haveChr		;(10) byte received

	dcx	b		;(5) otherwise, decrement timer
	mov	a,b		;(5) one second expire?
	ora	c		;(4)
	jnz	rcvWait		;(10) no, keep waiting

; one second timeout has occured. Decrement the seconds counter.

	dcr	d		;decrement seconds counter
	jnz	initSec		;initialize for another 1 second count
haveChr	pop	d		;restore d, e
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

chkCtlc	ani	7fh
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

ramEnd	dcr	h		;hl=end of RAM + 1
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
; subHlDe - HL=HL-DE
;--------------------------------------------------------------------
subHlDe	mov	a,l		;subtract HL-DE, do lsbs first
	sub	e
	mov	l,a		;lsb result in l
	mov	a,h		;do msbs
	sbb	d
	mov	h,a		;msb result in h	
	ret

;-----------------------------------------------------------------------------
;   Data Area
;-----------------------------------------------------------------------------
mWelcom	db	cr,lf,lf
	db 	'===== PC to Floppy Disk Image Transfer =====',cr,lf
	db	'      (DJ2D Controller @ E000, ver 1.1)',cr,lf,lf
	db	'Writes an 8" floppy with a disk imaged received via the'
	db	cr,lf
	db	'DJ2D or 88-2SIO serial port using the XMODEM protocol.',0

mDrive	db	cr,lf,lf,'Insert and specify destination drive ('
mDrvMin	db	'x-'
mDrvMax	db	'x) or X to exit: ',0

mVerify	db	cr,lf,lf
	db	'Verify writes (Y or N)? ', 0

mPort	db	cr,lf,lf
	db	'Specify the port to use for file transfer',cr,lf
	db	'  1) DJ2D (which is also the console port)',cr,lf
	db	'  2) 88-2SIO port A',cr,lf
	db	'  3) 88-2SIO port B',cr,lf
	db	'Enter 1-3 or X to exit: ',0

mStart	db	cr,lf,lf
	db	'Start XMODEM send now...',0

mDone	db	cr,lf,lf,'Creation of new disk successful!',cr,lf,0

mNoTrk0	db	cr,lf,lf,'Seek to track 0 failed',cr,lf,0

mNoSec	db	cr,lf,lf,'Sector not found - disk not formatted?',0

mDskErr	db	cr,lf,lf,'Write failure on track '
errTrk	db	'xx, sector '
errSec	db	'xx. Disk creation aborted.',cr,lf,0

mNotRdy	db	cr,lf,lf,'Drive is not ready',cr,lf,0
mWrtPrt	db	cr,lf,lf,'Disk is write protected',cr,lf,0
mCrcErr	db	cr,lf,lf,'CRC error',cr,lf,0
mUnkErr	db	cr,lf,lf,'Unknown write error',cr,lf,0

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
;    clobbers a
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
; dSelDrv - Select drive specified in drvNum 
; On Entry:
;    drvNum = drive to be selected
; On Exit:
;    drive selected
; Clobbers c
;--------------------------------------------------------------
dSelDrv	lda	drvNum		;a=desired drive
	mov	c,a
	call	SELDRV
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
	jz	dScFmtA		;yes, set sector data and exit

; restore failed

	lxi	h,mNoTrk0

errMsg	call	dispMsg
	lxi	sp,ourStk	;initialize stack pointer
	jmp	getDrv		;start over asking for drive num

;--------------------------------------------------------------
; dSeek - Seek track specified in A. If track is 0 or 1, read
;    sector 1 to and determine format.
; On Entry:
;    a = desired track
; On Exit:
;    secFmt - sector length (0-3)
;    numSecs - sectors per track (26,26,15,8)
;    secLen - sector length (128,256,512,1024)
;    trkLen - numSecs * secLen
;    C flag clear = good, C flag set = error
; Clobbers c
;--------------------------------------------------------------
dSeek	push	h		;save hl
	push	d		;save de

	mov	l,a

	call	dSelDrv		;make sure drive is selected

	mov	c,l		;track to c
	call	TRKSET		;set track
	cpi	2
	jnc	dSeekRt		;return if track > 1

	lxi	h,secBuf	;temporary sector buffer
	mvi	e,1
	call	dRead		;read to update status
	call	dSecFmt		;get track's sector format

dSeekRt	pop	d		;restore hl
	pop	h		;restore de
	ret

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

	ora	a		;update zero flag

	pop	d		;restore de
	ret

;--------------------------------------------------------------
; dVerify - Verify sector on current track. The DJ2D PROM does
;    not provide a verify command, so we just read the sector.
; On Entry:
;    Drive is selected, on proper track
;    hl->sector buffer
;    e = sector number to verify
; On Exit:
;    Z flag set = good, Z flag clear = error
;    clobbers none
;--------------------------------------------------------------
dVerify	jmp	dRead		;verify the sector


;--------------------------------------------------------------
; dWrite - Write a sector on current track
; On Entry:
;    Drive is selected, on proper track, head loaded
;    hl->buffer address
;    e = sector number to write
; On Exit:
;    Z flag set = good, Z flag clear = error
;   clobbers h,l
;--------------------------------------------------------------
dWrite	push	d		;save de
	mov	c,e		;sector number in c
	call	SETSEC		;set sector
	mov	b,h		;bc = hl
	mov	c,l
	call	SETDMA
	call	WRITE
	pop	d		;restore de
	ora	a		;update zero flag

	ret

;--------------------------------------------------------------
; dChkErr - check error status bits
; On Entry:
;    a = DJ2D error bits
; On Exit:
;    returns if no error. Otherwise, an error
;    message is displayed and the program starts over.
; Clobbers none
;--------------------------------------------------------------
dChkErr	ora	a		;test for error
	rz			;return if no error

	lxi	h,mNotRdy	;not ready message
	ral			;not ready bit?
	jc	errMsg		;no, check next bit

	lxi	h,mWrtPrt	;write protect messages
	ral			;write protect bit?
	jc	errMsg		;no, check next bit

	lxi	h,mNoSec	;sector not found message
	ral			;unused bit
	ral			;write protect bit?
	jc	errMsg		;no, check next bit

	lxi	h,mCrcErr	;CRC error message
	ral			;CRC error bit?
	jc	errMsg		;no, check next bit

	lxi	h,mUnkErr	;Unknown error message
	jmp	errMsg

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
;
; dScFmtA - Status already in A
;
; On Entry:
;    drive selected
; On Exit:
;    numSecs - sectors per track (26,26,15,8)
;    secLen - sector length (128,256,512,1024)
;    trkLen - track length
;--------------------------------------------------------------
dSecFmt	call	STATUS
	rar			;sector length is bits 2-3
dScFmtA	ani	06h		;a=2*length code
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
; Disk variables

drvNum	ds	1		;drive number to use
trkNum	ds	1		;track number to read
secFmt	ds	1		;0=128,1=256,2=512,3=1024
secLen	ds	2		;sector length
numSecs	ds	1		;number of sectors per track
trkLen	ds	2		;track length
trkPtr	ds	2		;pointer into trkBuf
skewPtr	ds	2		;pointer to skew table
bufEnd	ds	2		;end address + 1 of last track spot in RAM

; Retry logic variables

vfyFlag	ds	1		;verify writes flag
rdRetry	ds	1		;disk read retry counter
wrRetry	ds	1		;disk write retry counter

; Xmodem variables

xfrPort	ds	1		;pseudo port for file transfer
blkNum	ds	1		;current xmodem block number
rcvBlk	ds	1		;block number received
rcvNBlk	ds	1		;"not" block number received
rcvPtr	ds	2		;pointer for start of XMODEM send
eotFlag	ds	1		;EOT received flag

; Misc variables

cpmFlag	ds	1		;non-zero if running under CP/M
baseDrv	ds	1		;ascii 1st drive - baseDrv = 0
	ds	96		;stack space
ourStk	equ	$

; Temporary sector buffer

secBuf	ds	1024

; Track buffer runs from here to the end of memory
; Put on page boundary for easier debugging

trkBuf	equ	($+0100h) and 0ff00h

	end

