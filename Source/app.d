/*
 * Copyright (c) 2026 okzyrox
 *
 * This file is licensed under a 5-clause modified BSD license. Use, modification, 
 * and redistribution are subject to the terms and restrictions in the LICENSE,
 * which can be obtained in the Project Root.
 *
 * 
*/

import std.stdio;

import bindbc.sdl;

void main()
{
    loadSDL();
    SDL_Init(SDL_INIT_VIDEO);

    writeln("Hi SDL!!");

    SDL_Quit();
}
