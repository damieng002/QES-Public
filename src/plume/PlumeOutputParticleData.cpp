/****************************************************************************
 * Copyright (c) 2024 University of Utah
 * Copyright (c) 2024 University of Minnesota Duluth
 *
 * Copyright (c) 2024 Behnam Bozorgmehr
 * Copyright (c) 2024 Jeremy A. Gibbs
 * Copyright (c) 2024 Fabien Margairaz
 * Copyright (c) 2024 Eric R. Pardyjak
 * Copyright (c) 2024 Zachary Patterson
 * Copyright (c) 2024 Rob Stoll
 * Copyright (c) 2024 Lucas Ulmer
 * Copyright (c) 2024 Pete Willemsen
 *
 * This file is part of QES-Plume
 *
 * GPL-3.0 License
 *
 * QES-Plume is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, version 3 of the License.
 *
 * QES-Plume is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with QES-Plume. If not, see <https://www.gnu.org/licenses/>.
 ****************************************************************************/

/** @file PlumeOutputParticleData.cpp
 * @brief This class handles saving output files for Lagrangian particle data.
 * This is a specialized output class derived and inheriting from QESNetCDFOutput.
 *
 * @note child of QESNetCDFOutput
 * @sa QESNetCDFOutput
 */

#include "PlumeOutputParticleData.h"
#include "Plume.hpp"

// note that this sets the output file and the bool for whether to do output, in the netcdf inherited classes
PlumeOutputParticleData::PlumeOutputParticleData(PlumeInputData *PID, Plume *plume_ptr, std::string output_file)
  : QESNetCDFOutput(output_file)
{
  // setup desired output fields string
  // -> possible output fields
  /*output_fields = { "t","parID","tStrt","sourceIdx",
      "xPos_init","yPos_init","zPos_init",
      "xPos","yPos","zPos",
      "uFluct","vFluct","wFluct",
      "delta_uFluct","delta_vFluct","delta_wFluct",
      "isRogue","isActive"};*/


  std::cout << "[PlumeOutputParticleData] set up NetCDF file " << output_file << std::endl;

  // setup copy of disp pointer so output data can be grabbed directly
  m_plume = plume_ptr;

  if (PID->partOutParams == nullptr) {
    std::cerr << "[PlumeOutputParticleData] ERROR missing particleOutputParameters from input parameter file" << std::endl;
    exit(EXIT_FAILURE);
  }

  std::vector<std::string> fileOP = PID->partOutParams->outputFields;
  bool valid_output;

  if (fileOP.empty() || fileOP[0] == "all") {
    output_fields = allOutputFields;
  } else if (fileOP[0] == "minimal") {
    output_fields = minimalOutputFields;
  } else {
    output_fields = { "parID", "tStrt", "sourceIdx", "isActive" };
    output_fields.insert(output_fields.end(), fileOP.begin(), fileOP.end());
  }

  valid_output = validateFileOptions_local();

  if (!valid_output) {
    std::cerr << "[PlumeOutputParticleData] ERROR invalid output fields for visulization fields output" << std::endl;
    exit(EXIT_FAILURE);
  }

  // setup output frequency control information
  // FM future work: need to create dedicated input variables
  //  LA: we want output from the simulation start time to the end so the only dedicated input variable still needed
  //   would be an output frequency. For now, use the updateFrequency_timeLoop variable for the outputFrequency.
  // LA note: because the time counter in this class uses time and not a timeIdx, also need to use the timestep

  // time to start output, adjusted if the output duration does not divide evenly by the output frequency
  if (PID->partOutParams->outputStartTime < 0)
    outputStartTime = m_plume->getSimTimeStart();
  else
    outputStartTime = m_plume->getSimTimeStart() + PID->partOutParams->outputStartTime;

  // output frequency
  outputFrequency = PID->partOutParams->outputFrequency;

#if 0 
  // Determine whether outputStartTime needs adjusted to make the output duration divide evenly by the output frequency
  // This is essentially always keeping the outputEndTime at what it is (end of the simulation), and adjusting the outputStartTime
  // to avoid slicing off an output time unless we have to.
  float outputDur = outputEndTime - outputStartTime;
  // if doesn't divide evenly, need to adjust outputStartTime
  // can determine if it divides evenly by comparing the quotient with the decimal division result
  //  if the values do not match, the division has a remainder
  //  here's hoping numerical error doesn't play a role
  float quotient = std::floor(outputDur / outputFrequency);
  float decDivResult = outputDur / outputFrequency;
  if (quotient != decDivResult) {
    // clever algorythm that always gets the exact number of outputs when output duration divides evenly by output frequency
    // and rounds the number of outputs down to what it would be if the start time were the next smallest evenly dividing number
    int nOutputs = std::floor(outputDur / outputFrequency) + 1;

    // clever algorythm to always calculate the desired output start time based off the number of outputs
    // the outputStartTime if not adjusting nOutputs
    float current_outputStartTime = outputEndTime - outputFrequency * (nOutputs - 1);
    // the outputStartTime if adjusting nOutputs. Note nOutputs has one extra outputs
    float adjusted_outputStartTime = outputEndTime - outputFrequency * (nOutputs);
    if (adjusted_outputStartTime >= simStartTime) {
      // need to adjust the outputStartTime to be the adjusted_outputStartTime
      // warn the user that the outputStartTime is being adjusted before adjusting outputStartTime
      std::cout << "[PlumeOutputParticleData] "
                << "adjusting outputStartTime because output duration did not divide evenly by outputFrequency" << std::endl;
      std::cout << "  original outputStartTime = \"" << outputStartTime
                << "\", outputEndTime = \"" << outputEndTime
                << "\", outputFrequency = \"" << outputFrequency
                << "\", new outputStartTime = \"" << adjusted_outputStartTime << "\"" << std::endl;
      outputStartTime = adjusted_outputStartTime;
    } else {
      // need to adjust the outputStartTime to be the current_outputStartTime
      // warn the user that the outputStartTime is being adjusted before adjusting outputStartTime
      std::cout << "[PlumeOutputParticleData] "
                << "adjusting outputStartTime because output duration did not divide evenly by outputFrequency" << std::endl;
      std::cout << "  original outputStartTime = \"" << outputStartTime
                << "\", outputEndTime = \"" << outputEndTime
                << "\", outputFrequency = \"" << outputFrequency
                << "\", new outputStartTime = \"" << current_outputStartTime << "\"" << std::endl;
      outputStartTime = current_outputStartTime;
    }
  }// else does divide evenly, no need to adjust anything so no else
#endif

  // set the initial next output time value
  nextOutputTime = outputStartTime;

  // --------------------------------------------------------
  // setup the paricle information storage
  // --------------------------------------------------------

  // get total number of particle to be released
  numPar = m_plume->getTotalParsToRelease();
  std::cout << "[PlumeOutputParticleData] total number of particle to be saved in file " << numPar << std::endl;

  // initialize all the output containers
  // normally this is done by doing a resize, then setting values later,
  // but the full output needs initial values that match the particle values from the get go
  // so I will add them by pushback
  for (int par = 0; par < numPar; par++) {
    parID.push_back(par);
  }

  tStrt.resize(numPar, 0);
  sourceIdx.resize(numPar, 0);

  d.resize(numPar, 0.0);
  m.resize(numPar, 0.0);
  wdecay.resize(numPar, 0.0);

  xPos_init.resize(numPar, 0);
  yPos_init.resize(numPar, 0);
  zPos_init.resize(numPar, 0);

  xPos.resize(numPar, 0);
  yPos.resize(numPar, 0);
  zPos.resize(numPar, 0);

  uMean.resize(numPar, 0);
  vMean.resize(numPar, 0);
  wMean.resize(numPar, 0);

  uFluct.resize(numPar, 0);
  vFluct.resize(numPar, 0);
  wFluct.resize(numPar, 0);

  delta_uFluct.resize(numPar, 0);
  delta_vFluct.resize(numPar, 0);
  delta_wFluct.resize(numPar, 0);

  isRogue.resize(numPar, 0);
  isActive.resize(numPar, 0);

  // --------------------------------------------------------
  // setup the netcdf output information storage
  // --------------------------------------------------------

  setStartTime(m_plume->getSimTimeStart());

  // set data dimensions, which in this case are cell-centered dimensions
  // particles dimensions
  NcDim NcDim_par = addDimension("parID", numPar);

  // create attributes space dimensions
  std::vector<NcDim> dim_vect_par;
  dim_vect_par.push_back(NcDim_par);
  createAttVector("parID", "particle ID", "--", dim_vect_par, &parID);


  // create 2D vector and put in the dimensions (time,par).
  // !!! make sure the order is specificall nt,nPar in this spot,
  //  the order doesn't seem to matter for other spots
  std::vector<NcDim> dim_vect_2d;
  dim_vect_2d.push_back(NcDim_t);
  dim_vect_2d.push_back(NcDim_par);

  // create attributes for adding all particle information
  createAttVector("tStrt", "particle-release-time", "s", dim_vect_2d, &tStrt);
  createAttVector("sourceIdx", "particle-sourceID", "--", dim_vect_2d, &sourceIdx);

  createAttVector("d", "diameter ofarticle", "mu-m", dim_vect_2d, &d);
  createAttVector("m", "mass of particle", "g", dim_vect_2d, &m);
  createAttVector("wdecay", "non-decay fraction", "--", dim_vect_2d, &wdecay);

  createAttVector("xPos_init", "initial-x-position", "m", dim_vect_2d, &xPos_init);
  createAttVector("yPos_init", "initial-y-position", "m", dim_vect_2d, &yPos_init);
  createAttVector("zPos_init", "initial-z-position", "m", dim_vect_2d, &zPos_init);

  createAttVector("xPos", "x-position", "m", dim_vect_2d, &xPos);
  createAttVector("yPos", "y-position", "m", dim_vect_2d, &yPos);
  createAttVector("zPos", "z-position", "m", dim_vect_2d, &zPos);

  createAttVector("uMean", "u-mean-velocity", "m s-1", dim_vect_2d, &uMean);
  createAttVector("vMean", "v-mean-velocity", "m s-1", dim_vect_2d, &vMean);
  createAttVector("wMean", "w-mean-velocity", "m s-1", dim_vect_2d, &wMean);

  createAttVector("uFluct", "u-velocity-fluctuation", "m s-1", dim_vect_2d, &uFluct);
  createAttVector("vFluct", "v-velocity-fluctuation", "m s-1", dim_vect_2d, &vFluct);
  createAttVector("wFluct", "w-velocity-fluctuation", "m s-1", dim_vect_2d, &wFluct);

  createAttVector("delta_uFluct", "uFluct-difference", "m s-1", dim_vect_2d, &delta_uFluct);
  createAttVector("delta_vFluct", "vFluct-difference", "m s-1", dim_vect_2d, &delta_vFluct);
  createAttVector("delta_wFluct", "wFluct-difference", "m s-1", dim_vect_2d, &delta_wFluct);

  createAttVector("isRogue", "is-particle-rogue", "bool", dim_vect_2d, &isRogue);
  createAttVector("isActive", "is-particle-active", "bool", dim_vect_2d, &isActive);


  // create output fields
  addOutputFields();
}

bool PlumeOutputParticleData::validateFileOptions_local()
{
  // removing duplicate
  sort(output_fields.begin(), output_fields.end());
  output_fields.erase(unique(output_fields.begin(), output_fields.end()), output_fields.end());

  // check if all outputFields are possible
  bool doContains(true);
  std::size_t iter = 0, maxiter = output_fields.size();

  while (doContains && iter < maxiter) {
    doContains = find(allOutputFields.begin(), allOutputFields.end(), output_fields.at(iter)) != allOutputFields.end();
    iter++;
  }

  return doContains;
}


void PlumeOutputParticleData::save(QEStime timeIn)
{
  // only output if it is during the next output time but before the end time
  if (timeIn >= nextOutputTime) {
    // copy particle info into the required output storage containers
    for (auto &parItr : m_plume->particleList) {

      int parID = parItr->particleID;

      tStrt[parID] = (float)parItr->tStrt;
      sourceIdx[parID] = parItr->sourceIdx;
      d[parID] = (float)parItr->d;
      m[parID] = (float)parItr->m;
      wdecay[parID] = (float)parItr->wdecay;

      xPos_init[parID] = (float)parItr->xPos_init;
      yPos_init[parID] = (float)parItr->yPos_init;
      zPos_init[parID] = (float)parItr->zPos_init;

      xPos[parID] = (float)parItr->xPos;
      yPos[parID] = (float)parItr->yPos;
      zPos[parID] = (float)parItr->zPos;

      uMean[parID] = (float)parItr->uMean;
      vMean[parID] = (float)parItr->vMean;
      wMean[parID] = (float)parItr->wMean;

      uFluct[parID] = (float)parItr->uFluct;
      vFluct[parID] = (float)parItr->vFluct;
      wFluct[parID] = (float)parItr->wFluct;

      delta_uFluct[parID] = (float)parItr->delta_uFluct;
      delta_vFluct[parID] = (float)parItr->delta_vFluct;
      delta_wFluct[parID] = (float)parItr->delta_wFluct;

      // since no boolean output exists, going to have to convert the values to ints
      if (parItr->isRogue)
        isRogue[parID] = 1;
      else
        isRogue[parID] = 0;

      if (parItr->isActive)
        isActive[parID] = 1;
      else
        isActive[parID] = 0;
    }


    // set output time for correct netcdf output
    timeCurrent = timeIn;

    // save the fields to NetCDF files
    saveOutputFields();

    // update the next output time so output only happens at output frequency
    nextOutputTime = nextOutputTime + outputFrequency;
#if 0
    // reset buffers
    for (auto i = 0u; i < isActive.size(); i++) {
      tStrt[i] = 0;
      sourceIdx[i] = 0;

      xPos_init[i] = 0;
      yPos_init[i] = 0;
      zPos_init[i] = 0;

      xPos[i] = 0;
      yPos[i] = 0;
      zPos[i] = 0;

      uMean[i] = 0;
      vMean[i] = 0;
      wMean[i] = 0;

      uFluct[i] = 0;
      vFluct[i] = 0;
      wFluct[i] = 0;

      delta_uFluct[i] = 0;
      delta_vFluct[i] = 0;
      delta_wFluct[i] = 0;

      isRogue[i] = 0;
      isActive[i] = 0;
    }
#endif
  }
}
