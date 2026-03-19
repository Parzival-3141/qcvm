//==============================================================================
//
// MIT License
//
// Copyright (c) 2023-2026 erysdren (it/its)
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
// 
//==============================================================================

#pragma target vanilla
#pragma warning disable Q208
#pragma progs_dat hello.dat
#pragma autoproto

// globals
entity gtest;

void end_sys_globals;

// fields
.float field3;
.float field4;
.float field6;
.float field1;
.string field2;
.vector vec_field;

void end_sys_fields;

// builtins
entity spawn() = #1 : spawn;
void printf(string s, ...) = #2 : printf;
string sprintf(string s, ...) = #3 : sprintf;

void main()
{
    entity ent;
    float x, y, z;
    string str;

    gtest = create(4643, "hello world!");

    x = 1 + 2;
    y = x * 4;
    z = y / x;
    ent = spawn();
    ent.field1 = 352;
    ent.field2 = "foobar!!!";

    vector v = [x, y, z];
    if(x == 5) {
        v = v + [1, 2, 3];
    } else if(x <= 3) {
        v = v - [z, y, x];
    }

    ent.vec_field = v;

    printf("sup\n");
    printf("%f %s\n", gtest.field1, gtest.field2);
    printf("%f %s %v\n", ent.field1, ent.field2, ent.vec_field);

    printf("%f, %f, %v\n", 1, 7543, [0.02, 0.0654, 100.2]);
    printf("%s %s %s\n", "multi", "part", "sentence");

    str = sprintf("%v", [111, 3623.56, 0.124]);
    printf("%s\n", str);

    str = sprintf("0 %f %f %f %f %f %f %f",
                      1, 2, 3, 4, 5, 6, 7);
    printf("%s\n", str);

}

entity(float f1, string f2) create = {
    entity ent = spawn();
    ent.field1 = f1;
    ent.field2 = f2;
    return ent;
}
