/*
 * SpectRE - A Spectral Code for Reheating
 * Copyright (C) 2009-2010 Hal Finkel, Nathaniel Roth and Richard Easther
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES,
 * INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY
 * AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL
 * THE AUTHORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS;
 * OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
 * WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR
 * OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
 * ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

/**
 * @file
 * @brief LatticeEasy-style initialization.
 */

#ifndef LE_STYLE_INITIALIZER_HPP
#define LE_STYLE_INITIALIZER_HPP

#include "model_params.hpp"
#include "field.hpp"
#include "initializer.hpp"

#include <cmath>
#include <cufftw.h>

template <typename R>
class le_style_initializer : public initializer<R>
{
public:
	le_style_initializer(field<R> &phi_, field<R> &phidot_,
			     IF_CHI_ARG(field<R> &chi_,)
			     IF_CHI_ARG(field<R> &chidot_,)
			     R adot_, R len0)
		: phi(phi_), phidot(phidot_),
		  IF_CHI_ARG(chi(chi_),)
		  IF_CHI_ARG(chidot(chidot_),)
		adot(adot_)
	{
		using namespace std;
		
		fluctuation_amplitude = RESCALE_A * RESCALE_B * NTOTAL_GRIDPOINTS /
				(pow(MP_LEN/len0, (R) 1.5) * sqrt(2.));
	}

public:
	virtual void initialize();

protected:
	void set_mode(fftw_complex *fld, fftw_complex *flddot, R m_fld_eff, int px, int py, int pz, int idx, bool real = false);
	void initialize_field(field<R> &fld, field<R> &flddot, R m_fld_eff);

protected:
	field<R> &phi, &phidot;
	IF_CHI(field<R> &chi;)
	IF_CHI(field<R> &chidot;)
	R adot;
	R fluctuation_amplitude;
};

#endif // LE_STYLE_INITIALIZER_HPP
