;main.asm
;
;Main program
;
;Copyright (C) 2006, Brian Shucker <brian@iguanaworks.net>
;Copyright (C) 2007, Joseph Dunn <jdunn@iguanaworks.net>
;
;Distribute under the GPL version 2.
;See COPYING for license details.

; define the start of relocatable code to move this as far back as possible.
; Project -> Settings -> Linker -> Relocatable start address:
;          '%x' % (8192 - (CODESIZE / 64 + 1 + 1) * 64)
; NOTE: we will overwrite the send function at 0x1c00!

include "m8c.inc"         ; part specific constants and macros
include "memory.inc"      ; Constants & macros for SMM/LMM and Compiler
include "PSoCAPI.inc"     ; PSoC API definitions for all User Modules
include "constants.inc"

; exported functions
export _main
export soft_reset

; exported variables
export buffer_ptr
export halted

; exported temporary variables
export tmp1
export tmp2

AREA bss

; real variables
buffer_ptr:
	BLK 1 ;current index into buffer
write_ptr:
	BLK 1 ;current index where we are writing from buffer to USB
buf_size:
	BLK 1 ;amount of data currently in buffer
halted:
	BLK 1 ;true if endpoint was halted

; temporary storage locations
tmp1:
	BLK 1
tmp2:
	BLK 1
flash_addr:
	BLK 1

AREA text

_main:
	mov A, 0 ;put arg 0 for USB_start
	lcall USB_Start ;enable USB device
	or  F, 0x1 ;enable global interrupts

;wait for usb enumeration
config_loop:
	lcall USB_bGetConfiguration
	jz config_loop ; if return val was zero, try again

; now we're connected
soft_reset:
	mov [halted], 0 ; clear halt flag that Linux sets

	; clear the IN endpoint by sending 0-byte packet
	mov [USB_APIEPNumber], 0x1 ; set to endpoint 1
	mov [USB_APICount], 0      ; set packet size
	mov X, buffer              ; put packet address into X
	lcall USB_XLoadEP          ; send packet

	; enable OUT endpoint
	MOV A, OUT
	lcall USB_EnableEP

main_loop:
    ; halt condition 
	mov A, [halted]; check for halt condition
	jnz soft_reset ; go to known state after halt

	; check for data from host
	lcall check_read ; see if there is a transmission from the host
	jnz main_recv    

	; repeat main loop
	jmp main_loop

; there is a transmission, so receive and handle it
main_recv:
	; get control packet
	lcall read_control

	;at this point, A contains control code
	jz main_loop       ; null control code, just ignore
	cmp A, CTL_VERSION ; get version
	jz main_getversion
	cmp A, CTL_PROG    ; program a block of flash
	jz main_prog
	cmp A, CTL_CHKSUM  ; checksum block of flash
	jz main_chksum
	cmp A, CTL_RST     ; reset command
	jz main_reset

	jmp main_loop ; default behavior--unknown code

main_getversion:
	; send control packet with version id
	mov [control_pkt + CCODE], CTL_VERSION
	mov [control_pkt + CDATA + 0], VERSION_ID_LOW
	mov [control_pkt + CDATA + 1], VERSION_ID_HIGH
	mov A, CTL_BASE_SIZE + 2
	lcall write_control
	jmp main_loop

main_prog:
	mov [flash_addr], [control_pkt + CDATA] ;read the flash block address
	mov [control_pkt + CDATA], FLASH_BLOCK_SIZE ;set up to read right number of bytes into buffer
	lcall read_buffer ;get the block

	; ack the receive
	mov [control_pkt + CCODE], CTL_PROG
	mov A, CTL_BASE_SIZE
	lcall write_control

	; wait for ack to go through so that the control_pkt buffer is unused
	lcall wait_for_IN_ready

	; do a block erase
	mov A, 0x03 ;erase block code
	call exec_ssc

	;now set up the parameter block for the SROM call
	mov A, 0x02 ;write block code
	call exec_ssc

	jmp main_loop ; read the next packet

; checksum an individual page much like the ssc checksum function
main_chksum:
	; read a page of flash
	mov [flash_addr], [control_pkt + CDATA]
	mov A, 0x01 ;read block code
	call exec_ssc

	; compute a very simple checksum
	mov X, FLASH_BLOCK_SIZE
	mov [tmp1], 0
	mov [tmp2], 0
  mcsum_loop:
	dec X
	mov A, [X + buffer]
	add [tmp2], A ; add to the low byte
	adc [tmp1], 0 ; sum the overflows in the high byte
	mov A, X
	jnz mcsum_loop

	; return the checksum to the PC with the KEY1/KEY2 values
	mov [control_pkt + CCODE], CTL_CHKSUM
	mov [control_pkt + CDATA + 0], [tmp1]
	mov [control_pkt + CDATA + 1], [tmp2]
	mov [control_pkt + CDATA + 2], [KEY2]
	mov [control_pkt + CDATA + 3], [KEY1]
	mov A, CTL_BASE_SIZE + 4
	lcall write_control
 
	; read the next packet
	jmp main_loop

main_reset:
	lcall USB_Stop ; have to do this first, or we loop sending 0 length packets....
	mov [flash_addr], 0x0
	mov A, 0 ;reset code
	call exec_ssc

; pre: flash_addr holds the block index
;      A holds the ssc code
exec_ssc:
	; store the ssc code
	mov [tmp1], A

	;now set up the parameter block for the SROM call
	mov [KEY1], 0x3A;
	mov X, SP                   ; get stack pointer
	mov A, X
	add A, 3                    ; just following directions from datasheet
	mov [KEY2], A
	mov [BLOCKID], [flash_addr] ; set which flash block to write
	mov [POINTER], buffer       ; write data to the buffer
	mov [CLOCK], 0x00           ; guessing at the right clock divider
	mov [DELAY], 0xAC           ; this is a guess, since datasheet says use 0x56 for 12MHz
	mov A, [tmp1]               ; load the ssc code
	ssc                         ; execute it
	ret