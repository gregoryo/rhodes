/*------------------------------------------------------------------------
* (The MIT License)
* 
* Copyright (c) 2008-2011 Rhomobile, Inc.
* 
* Permission is hereby granted, free of charge, to any person obtaining a copy
* of this software and associated documentation files (the "Software"), to deal
* in the Software without restriction, including without limitation the rights
* to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
* copies of the Software, and to permit persons to whom the Software is
* furnished to do so, subject to the following conditions:
* 
* The above copyright notice and this permission notice shall be included in
* all copies or substantial portions of the Software.
* 
* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
* IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
* FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
* AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
* LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
* OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
* THE SOFTWARE.
* 
* http://rhomobile.com
*------------------------------------------------------------------------*/

#pragma once

#include "stdafx.h"

#include <stdlib.h>
#include <windows.h>
#include <commctrl.h>

#if defined(_WIN32_WCE)
#include <imaging.h>
#else
struct IImage;
#endif

#include <string>
#include <string>
#include "ext/rho/rhoruby.h"
#include "common/StringConverter.h"

#include <common/rhoparams.h>
#include <common/map/MapEngine.h>


using namespace rho::common;
using namespace rho::common::map;
using namespace rho;
using namespace stdext;



class WMAlphaBitmap {
public:
	WMAlphaBitmap(IImage* img);
	virtual ~WMAlphaBitmap();
	virtual int width() const {return mWidth;}
	virtual int height() const {return mHeight;}
	
	virtual void draw(unsigned short int *buf, int lineSizeInBytes);

private:
	unsigned int *mImgBuf;
	int mWidth;
	int mHeight;
};

class WMBitmap {
public:
	WMBitmap(IImage* img, bool useAlpha);
	virtual public ~WMBitmap();

	virtual void draw(HDC hdc, int x, int y);

	virtual void addRef();
	virtual void release();

	virtual int width() const {return mWidth;}
	virtual int height() const {return mHeight;}

private:
//	HDC mMemoryDC;
	HBITMAP mMemoryBitmap;
	unsigned short* mBuf; // do not delete it - it controlled by Bitmap
	int mWidth;
	int mHeight;
	int mRowByteSize;
	int mReferenceCount;
	WMAlphaBitmap* mAlphaBitmap;
};


class DrawingImageImpl : public IDrawingImage {
public:
	DrawingImageImpl(void const *p, int size, bool useAlpha);
	DrawingImageImpl(const char* path, bool useAlpha);
	DrawingImageImpl(WMBitmap* bitmap);
	virtual ~DrawingImageImpl();
	
	virtual void draw(HDC hdc, int x, int y);

	virtual IDrawingImage* clone();

	virtual int width() const {return mWidth;}
	virtual int height() const {return mHeight;}

private:
	void init(const char* path, void const *p, int size, WMBitmap* bitmap, bool useAlpha);
	//IImage* mImage;
	WMBitmap* mBitmap;
	int mWidth;
	int mHeight;
	int mID;
};


class DrawingContextImpl : public IDrawingContext{
public:
	DrawingContextImpl(HDC hdc, int width, int height);
	virtual int getWidth();
	virtual int getHeight();
	virtual void drawImage(int x, int y, IDrawingImage* image);
	virtual void drawText(int x, int y, int nWidth, int nHeight, String const &text, int color);
	virtual void getTextRect(int x, int y, String &text, RECT* resultRect);
	virtual void fillRect(int x, int y, int width, int height, int color);
	virtual void drawLine(int x1, int y1, int x2, int y2, int color);


private:
	HDC mHDC;
	int mWidth;
	int mHeight;
};

class DrawingDeviceImpl : public IDrawingDevice
{
public:

	virtual IDrawingImage* createImage(String const &path, bool useAlpha) {
		return new DrawingImageImpl(path.c_str(), useAlpha);
	}
	virtual IDrawingImage* createImage(void const *p, size_t s, bool useAlpha) {
		return new DrawingImageImpl(p, s, useAlpha);
	}

	virtual IDrawingImage* cloneImage(IDrawingImage *image) {
		if (image == NULL) {
			return NULL;
		}
		return ((DrawingImageImpl*)image)->clone();
	}

	virtual void destroyImage(IDrawingImage* image) {
		delete image;
	};

	virtual void requestRedraw(){}
};