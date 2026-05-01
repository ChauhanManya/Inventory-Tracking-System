.dseg
page_1_buff:   .byte 80     ;80-byte page buffer
page_2_buff:   .byte 80     ;80-byte page buffer
number:        .byte 3      ;keypad num (max 3 digits)
scanned_data:  .byte 40     ;barcode receiver
unsigned:      .byte 1
Lora_buffer:   .byte 38
enter_flag:    .byte 1      ;set to 1 when ENTER is pressed (keypad)

.cseg

;r17 - stores page number do not use elsewhere (in main)
;r16 is used to transfer data between buffers - tables -USARTS

reset:
    jmp init

.org PORTE_PORT_vect            //kepad interrupt
    rjmp porte_isr
.org USART2_DRE_vect            //RF interrupt
    rjmp USART2_DRE_ISR
.org USART3_DRE_vect            //LCD interrupt
    rjmp USART3_DRE_ISR


init:
    ;LCD (USART3 on PB0)
    sbi VPORTB_DIR, 0           ;set PB0 as output, tx signal -LCD
    sbi VPORTB_OUT, 0           ;set PB0 to 1 -IDLE

    ;USART3_init:
    ldi r16, LOW(1667)
    sts USART3_BAUDL, r16
    ldi r16, HIGH(1667)
    sts USART3_BAUDH, r16
    ldi r16, 0b00000011
    sts USART3_CTRLC, r16       ;8N1
    ldi r16, 0b01000000
    sts USART3_CTRLB, r16       ;transmitting
    ldi r16, 0b00000001
    sts USART3_DBGCTRL, r16     ;pause when debugger halts CPU


    ;USART1_init: (Barcode scanner)
    cbi VPORTC_DIR, 1           ;receiver from scanner
    ;1. set baud rate
    ;(64*4*10^6)/(16*115.2*10^3) = 138.88888 = 139
    ldi r16, LOW(139)
    sts USART1_BAUDL, r16
    ldi r16, HIGH(139)
    sts USART1_BAUDH, r16
    ldi r16, 0x03
    sts USART1_CTRLC, r16
    ldi r16, 0b10000000
    sts USART1_CTRLB, r16       ;RX enable
    ;4.set DBGRUN
    ldi r16, 0b00000001
    sts USART1_DBGCTRL, r16


    ;USART2_init: (LoRa RF)
    sbi VPORTF_DIR, 4
    ldi r16, LOW(1667)
    sts USART2_BAUDL, r16
    ldi r16, HIGH(1667)
    sts USART2_BAUDH, r16
    ldi r16, 0b00000011
    sts USART2_CTRLC, r16       ;8N1
    ldi r16, 0b01000000
    sts USART2_CTRLB, r16       ;TX enable
    ldi r16, 0x10
    sts PORTMUX_USARTROUTEA, r16
    ldi r16, 0b00000001
    sts USART2_DBGCTRL, r16

    ;Keypad - lab 10 code 
    cbi VPORTE_DIR, 3           ;PE3 input (keypad INT)
    ldi r16, 0x00               ;set PC7-4 as input
    out VPORTC_DIR, r16         ;DA-PE3

    sei

main_loop:
    rcall build_page_1
    ldi r17, 0                  ;0 => first page - Intro
    rcall clear_page
    rcall transmit

    ldi r20, 200
    rcall delay_loop
    rcall clear_page

    rcall build_page_2
    ldi r17, 1					;2nd page - before entering inventory
    rcall transmit

    rcall enable_keypad_int     ;allow keypad to accept inputs now
    rcall process_number        ;ISR gathers up to 3 digits, wait for ENTER
    rcall convert_str_to_unsign

    ldi r17, 2                  ;2nd page - after entering inventory
    rcall transmit

    rcall scan_to_LCD           ;receive barcode and echo to LCD

    rcall load_lora_buffer
    rcall loading_info
    rcall Usart2_Enable

end:
    rjmp end                    ;stop here forever


build_page_1:
    ldi XL, low(page_1_buff)
    ldi XH, high(page_1_buff)
    ldi r18, 20

    ldi ZL, low(line1str<<1)
    ldi ZH, high(line1str<<1)
    rcall store_pg1_loop

    ldi ZL, low(line2str<<1)
    ldi ZH, high(line2str<<1)
    rcall store_pg1_loop

    ldi ZL, low(line3str<<1)
    ldi ZH, high(line3str<<1)
    rcall store_pg1_loop

    ldi ZL, low(line4str<<1)
    ldi ZH, high(line4str<<1)
    rcall store_pg1_loop
    ret

store_pg1_loop:                 ;store page 1 strings into buffer
    lpm r16, Z+
    st  X+, r16
    dec r18
    brne store_pg1_loop
    ldi r18, 20
    ret

line1str: .db "                    "
line2str: .db "Inventory System I  "
line3str: .db "ESE 280 Fall 2025   "
line4str: .db "Manya               "


build_page_2:
    ldi XL, low(page_2_buff)
    ldi XH, high(page_2_buff)

    ;line 1
    ldi r18, 20
    ldi ZL, low(page2_line1<<1)
    ldi ZH, high(page2_line1<<1)
    rcall storage_pg2_loop

    ;line 2 (empty)
    ldi r18, 20
    ldi ZL, low(page2_empty_lines<<1)
    ldi ZH, high(page2_empty_lines<<1)
    rcall storage_pg2_loop

    ;line 3
    ldi r18, 20
    ldi ZL, low(page2_line3<<1)
    ldi ZH, high(page2_line3<<1)
    rcall storage_pg2_loop

    ;line 4 (empty)
    ldi r18, 20
    ldi ZL, low(page2_empty_lines<<1)
    ldi ZH, high(page2_empty_lines<<1)
    rcall storage_pg2_loop
    ret

storage_pg2_loop:
    lpm r16, Z+
    st  X+, r16
    dec r18
    brne storage_pg2_loop
    ret

page2_empty_lines: .db "                    "
page2_line1:       .db "Enter item count:   "
page2_line3:       .db "Scan barcode:       "


clear_page:
    ldi r16, 0x7C               ;access settings of LCD
    rcall send_USART3
    ldi r16, 0x2D               ;clear
    rcall send_USART3
    ret

transmit:
    cpi r17, 0
    breq page_1
    cpi r17, 1
    breq page_2_line1
    cpi r17, 2
    breq page_2_line3

page_1:
    ldi XL, low(page_1_buff)
    ldi XH, high(page_1_buff)
    rjmp enable_DREIF

page_2_line1:
    ldi XL, low(page_2_buff)
    ldi XH, high(page_2_buff)
    rjmp enable_DREIF

page_2_line3:
    ldi XL, low(page_2_buff+40)
    ldi XH, high(page_2_buff+40)
    rjmp enable_DREIF

enable_DREIF:
    lds r19, USART3_CTRLA
    ori r19, 0x20               ;enable DRE interrupt
    sts USART3_CTRLA, r19
    ldi r18, 0                  ;init counter
    sei
    ret

USART3_DRE_ISR:
    cli
    ;save context
    push r16
    in   r16, CPU_SREG
    push r16
    push r17
    push r18
    push r19

    rcall transmit_data
    cpi  r18, 80
    brne restore_usart3_isr

    ;turn off DRE interrupt when done
    lds  r19, USART3_CTRLA
    andi r19, 0xDF              ;bit5 = 0
    sts  USART3_CTRLA, r19

restore_usart3_isr:
    pop  r19
    pop  r18
    pop  r17
    pop  r16
    out  CPU_SREG, r16
    pop  r16
    sei
    reti

transmit_data:
    ld  r16, X+                 ;x -> correct page buffer
    sts USART3_TXDATAL, r16
    inc r18                     ;increment counter
    ret

send_USART3:
wait_data_empty:
    lds  r21, USART3_STATUS
    sbrs r21, 5                 ;DREIF?
    rjmp wait_data_empty
    sts  USART3_TXDATAL, r16    ;send r16
    ret

enable_keypad_int:
    lds r16, PORTE_PIN3CTRL     ;set ISC for PE3, pos. edge
    ori r16, 0x02
    sts PORTE_PIN3CTRL, r16
    ret

process_number:
    ldi r22, 0                  ;digit count = 0
    ldi r16, 0
    sts enter_flag, r16

wait_enter_press:
    lds r16, enter_flag
    cpi r16, 1
    brne wait_enter_press

    ;ENTER pressed: send CR+LF to LCD
    ldi r16, 0x0D               ;carriage return
    rcall send_USART3
    ldi r16, 0x0A               ;new line
    rcall send_USART3
    ret

clear_number:
    ldi r18, 3
    ldi YL, low(number)
    ldi YH, high(number)
    ldi r16, 0
clear_loop:
    st  Y+, r16
    dec r18
    brne clear_loop
    ldi r22, 0                  ;reset digit count too
    ret

porte_isr:
    cli
    ;save context
    push r16
    in   r16, CPU_SREG
    push r16
    push r17
    push r18
    push r19
    push r22
    push r30
    push r31
    push r28
    push r29

    in   r16, VPORTC_IN
    lsr  r16
    lsr  r16
    lsr  r16
    lsr  r16
    andi r16, 0x0F
    rcall scan_to_value         ;r16 = key value

    ;clear PE3 interrupt flag
    ldi  r17, PORT_INT3_bm
    sts  PORTE_INTFLAGS, r17

    cpi  r16, 0x0D
    breq key_enter
    cpi  r16, 0x0E
    breq key_clear

key_digit:
    cpi  r22, 3
    brge done_key

    ;Y -> number + r22
    ldi  YL, low(number)
    ldi  YH, high(number)
	ldi r18, 0
    mov  r19, r22
    add  YL, r19
    adc  YH, r18     

    ;X -> page_2_buff+20 + r22
    ldi  XL, low(page_2_buff+20)
    ldi  XH, high(page_2_buff+20)
	ldi r18, 0
    mov  r19, r22
    add  XL, r19
    adc  XH, r18
    st   Y, r16

    ;store ASCII digit in LCD buffer and send to LCD
    ori  r16, 0x30
    st   X, r16
    rcall send_USART3

    inc  r22                    ;digit count++
    rjmp done_key

key_clear:
    ;if no digits, nothing to clear
    tst  r22
    breq done_key
    dec  r22

    ;Y -> number + r22
    ldi  YL, low(number)
    ldi  YH, high(number)
	ldi r18, 0
    mov  r19, r22
    add  YL, r19
    adc  YH, r18

    ;X -> page_2_buff+20 + r22
    ldi  XL, low(page_2_buff+20)
    ldi  XH, high(page_2_buff+20)
	ldi r18, 0
    mov  r19, r22
    add  XL, r19
    adc  XH, r18

    ldi  r18, 0
    st   Y, r18

    ;overwrite LCD buffer with space
    ldi  r18, ' '
    st   X, r18

    ;send backspace, space, backspace to LCD to visually erase
    ldi  r16, 0x08
    rcall send_USART3
    rjmp done_key

key_enter:
    ldi  r18, 1
    sts  enter_flag, r18
done_key:
    ;restore context
    pop  r29
    pop  r28
    pop  r31
    pop  r30
    pop  r22
    pop  r19
    pop  r18
    pop  r17
    pop  r16
    out  CPU_SREG, r16
    pop  r16
    sei
    reti

scan_to_value:
    ldi ZL, LOW(segtable << 1)
    ldi ZH, HIGH(segtable << 1)
    ldi r17, 0
    add ZL, r16
    adc ZH, r17
    lpm r16, Z
    ret

segtable:
   .db 0x01, 0x02, 0x03, 0x0A   ; 1, 2, 3, A
   .db 0x04, 0x05, 0x06, 0x0B   ; 4, 5, 6, B
   .db 0x07, 0x08, 0x09, 0x0C   ; 7, 8, 9, C
   .db 0x0E, 0x00, 0x0F, 0x0D   ; Clear, 0, Help, Enter


convert_str_to_unsign:
    ldi r16, 0                  ;accumulator
    ldi YL, low(number)
    ldi YH, high(number)

convert_loop:
    mov r23, r16
    ldi r18, 9
multiply_loop:
    add r16, r23
    dec r18
    brne multiply_loop

    ;add next digit
    ld  r23, Y+
    add r16, r23

    dec r22
    brne convert_loop

    ;store result
    ldi YL, low(unsigned)
    ldi YH, high(unsigned)
    st  Y, r16
    ret

scan_to_LCD:
    ldi YL, low(scanned_data)
    ldi YH, high(scanned_data)
store_until_CR:
    rcall receive_USART1
    st   Y+, r16
    cpi  r16, 0x0D
    brne store_until_CR

    ldi YL, low(scanned_data)
    ldi YH, high(scanned_data)
send_until_CR:
    ld   r16, Y+
    rcall send_USART3
    cpi  r16, 0x0D
    brne send_until_CR
receive_USART1:
    lds  r21, USART1_STATUS
    sbrs r21, 7
    rjmp receive_USART1
    lds  r16, USART1_RXDATAL
    ret

delay_loop:
   ldi r19, 100
   rcall var_delay
   dec r20
   brne delay_loop
   ret

var_delay:
outer_loop:
   ldi r16, 133
inner_loop:
   dec r16
   brne inner_loop
   dec r19
   brne outer_loop
   ret

;LAB 12
load_lora_buffer:
    ldi ZL, LOW(Lora << 1)
    ldi ZH, HIGH(Lora << 1)

    ldi YL, LOW(Lora_buffer)
    ldi YH, HIGH(Lora_buffer)

    ldi r16, 38
transfer:
    lpm r17, Z+
    st  Y+, r17
    dec r16
    brne transfer
    ret

Lora: .db "AT+SEND=100,18,Count=,ID=37"

loading_info:
    ; put count at position 21 in Lora_buffer
    ldi ZL, LOW(Lora_buffer + 21)
    ldi ZH, HIGH(Lora_buffer + 21)

    ; get first digit from number buffer
    ldi YL, LOW(number)
    ldi YH, HIGH(number)
	ldi r17, 3
loading_scan:
    ld  r16, Y+
	ori r16, 0x30
    st  Z+, r16
    dec r17
    brne loading_scan

    ldi r16, '\r'
    st  Z+, r16
    ldi r16, '\n'
    st  Z+, r16
    ret

USART2_DRE_ISR:
    cli
    push r16
    push r17
 
    ld  r16, Z+
    sts USART2_TXDATAL, r16
    cpi r16, '\n'
    breq USART2_DONE

    pop r17
    pop r16
    sei
    reti

USART2_DONE:
    ldi r16, 0x00
    sts USART2_CTRLA, r16
    pop r17
    pop r16
    sei
    reti

done:
    lds r16, USART2_CTRLA
    cpi r16, 0x00
    brne done
    ret

Usart2_Enable:
    ldi r16, 0x20          ;enable DRE interrupt
    sts USART2_CTRLA, r16
	ldi ZL, LOW(Lora_buffer)
    ldi ZH, HIGH(Lora_buffer)
    ret
