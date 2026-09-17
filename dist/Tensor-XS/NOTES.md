# NOTES:

https://ianparberry.com/art/ascii/color/

## IDEAS

- lazy matrix
    - ex: `$m1->add($m2)->mul($m3)->max(255);`
        - this will create several temp matricies 
        - a lazy version would prevent this 
    - operations do not immediately get applied
        - instead they are collected 
    - when the data is accessed, either:
        - all of it is calcuated at once (faster)
        - only the value's requested are calculated (slower)
    - the _slice method is the gateway to the $data array
    - any binary_op or unary_op can be lazyified
```

## 8-16 colors

        NORMAL | BRIGHT
        FG  BG | FG  BG
Black   30  40 | 90  100
Red     31  41 | 91  101
Green   32  42 | 92  102
Yellow  33  43 | 93  103
Blue    34  44 | 94  104
Magenta 35  45 | 95  105
Cyan    36  46 | 96  106
White   37  47 | 97  107
Default 39  49 | --  ---

# Set style to bold, red foreground.
\x1b[1;31mHello

# Set style to dimmed white foreground with red background.
\x1b[2;37;41mWorld

## 256

ESC[38;5;{ID}m  Set foreground color.
ESC[48;5;{ID}m  Set background color.

ID = 0 - 255

  0-7   : standard colors (as in ESC [ 30–37 m)
  8–15  : high intensity colors (as in ESC [ 90–97 m)
 16-231 : 6 × 6 × 6 cube (216 colors)
232-255 : grayscale from dark to light in 24 steps.

## RGB

ESC[38;2;{r};{g};{b}m   Set foreground color as RGB.
ESC[48;2;{r};{g};{b}m   Set background color as RGB.

```
